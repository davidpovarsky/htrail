'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');

const root = process.env.PURELINE_LAB_ROOT;
const run = process.env.PURELINE_BROWSER_RUN;
const revision = process.env.PURELINE_BACKEND_REVISION;
if (!root || !run || !revision || !/^[A-Za-z0-9_-]+$/.test(run))
  throw new Error('Explicit isolated root, unique run ID and frozen revision required.');
const fixtures = JSON.parse(fs.readFileSync(path.join(root, 'fixtures-public.json')));
const out = path.join(root, 'evidence', run);
const profile = path.join(root, 'profiles', run);
if (fs.existsSync(profile)) throw new Error('Use a fresh profile and run ID.');
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(profile, { recursive: true });
const cert = new crypto.X509Certificate(fs.readFileSync(path.join(root, 'mitmproxy-ca-cert.pem')));
const sha = data => crypto.createHash('sha256').update(data).digest('hex');
const spki = crypto.createHash('sha256').update(cert.publicKey.export({type:'spki',format:'der'})).digest('base64');
const proxy = 'http://127.0.0.1:18530';
const assets = fixtures.fixtures.map(item => ({
  ...item, url:'http://192.0.2.1/pureline-lab-20261127/fixtures/' + item.filename
}));
assets.push({
  filename:'public-wikisource.svg', expected:'allow', animated:false,
  url:'https://upload.wikimedia.org/wikipedia/commons/4/4c/Wikisource-logo.svg',
  sha256:'211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95'
});
async function health() {
  try { return await (await fetch(proxy + '/__pureline_lab_health', {signal:AbortSignal.timeout(5000)})).json(); }
  catch { return {error:'health_unavailable'}; }
}
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
(async()=>{
  const row = {
    run_id:run, started_at:new Date().toISOString(), backend_revision:revision,
    route:'Chromium -> explicit CONNECT/HTTP -> wireguard-go netstack -> framed UDP/SSH carrier -> isolated Oracle WireGuard -> real candidate filter',
    scope:'Rendered controlled fixtures plus one public HTTPS SVG. Not a physical iOS, public UDP, independent accuracy or whole-article test.',
    proxy, platform:process.platform, arch:process.arch,
    playwright:require('playwright/package.json').version,
    trust:{ignoreHTTPSErrors:false,ca_spki_sha256_base64:spki,global_trust_changes:false},
    health_before:await health(),assets:[],failures:[],passed:false
  };
  let context;
  try {
    context=await chromium.launchPersistentContext(profile,{
      headless:true,proxy:{server:proxy,bypass:'127.0.0.1,localhost'},
      args:['--ignore-certificate-errors-spki-list='+spki,'--disable-quic'],
      ignoreHTTPSErrors:false,viewport:{width:1100,height:900},acceptDownloads:false
    });
    row.browser=context.browser().version();
    const page=await context.newPage();
    page.on('requestfailed',r=>{
      const a=assets.find(a=>a.url===r.url());
      if(a)row.failures.push({fixture:a.filename,error:r.failure()?.errorText||'request_failed'});
    });
    await page.setContent('<!doctype html><meta charset="utf-8"><title>Pureline v5 acceptance</title><style>body{font:16px system-ui;background:#f4f7fb;color:#17243a;margin:30px}h1{font-size:28px}main{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}figure{margin:0;padding:18px;border:1px solid #cad5e4;border-radius:12px;background:white}img{display:block;width:250px;height:220px;object-fit:contain}figcaption{padding-top:16px;overflow-wrap:anywhere}.status{font-size:13px;color:#41556c}</style><h1>Pureline: bounded v5 browser acceptance</h1><p>Real filtering over an isolated WireGuard connection. Controlled public fixtures and one public HTTPS asset.</p><main id="gallery"></main>',{waitUntil:'domcontentloaded'});
    for(let i=0;i<assets.length;i++){
      const asset=assets[i], start=Date.now();
      const observed={fixture:asset.filename,url:asset.url,expected:asset.expected,expected_source_sha256:asset.sha256,passed:false};
      try {
        const wait=page.waitForResponse(r=>r.url()===asset.url,{timeout:45000});
        await page.evaluate(({asset,i})=>{
          const f=document.createElement('figure'),im=document.createElement('img'),cap=document.createElement('figcaption');
          im.id='asset-'+i;im.alt=asset.filename;im.src=asset.url;
          cap.textContent=asset.filename+' · Expected '+asset.expected;
          f.append(im,cap);document.getElementById('gallery').append(f);
        },{asset,i});
        const response=await wait,headers=await response.allHeaders(),body=await response.body();
        observed.response={
          status:response.status(),content_type:headers['content-type']||null,
          content_encoding:headers['content-encoding']||null,declared_content_length:headers['content-length']||null,
          action:headers['x-local-image-filter']||null,reason:headers['x-local-image-filter-reason']||null,
          presentation:headers['x-local-image-filter-presentation']||null,
          policy_exception:headers['x-local-image-filter-policy-exception']||null,
          decoded_body_bytes:body.length,decoded_body_sha256:sha(body)
        };
        await page.locator('#asset-'+i).evaluate(async im=>await im.decode(),{timeout:45000});
        observed.dom=await page.locator('#asset-'+i).evaluate(im=>({complete:im.complete,natural_width:im.naturalWidth,natural_height:im.naturalHeight,decode_resolved:true}));
        if(asset.animated){
          const captures=[];
          for(let n=0;n<3;n++){
            if(n)await delay(700);
            const file=asset.filename+'-frame-'+n+'.png';
            const pixels=await page.locator('#asset-'+i).screenshot({path:path.join(out,file),animations:'allow'});
            captures.push({screenshot:file,sha256:sha(pixels)});
          }
          observed.rendered_samples=captures;
          observed.animation_visible=new Set(captures.map(c=>c.sha256)).size>1;
        }
        const valid=observed.response.status===200 && observed.dom.complete && observed.dom.natural_width>0 && observed.dom.natural_height>0;
        const action=asset.expected==='allow'
          ? observed.response.action==='allow' && sha(body)===asset.sha256
          : ['blur','replace'].includes(observed.response.action) && sha(body)!==asset.sha256 && /^image\/(png|jpeg)$/.test(observed.response.content_type||'');
        const animation=!asset.animated || (asset.expected==='allow' ? observed.animation_visible : !observed.animation_visible);
        observed.passed=valid && action && animation && observed.response.policy_exception===null;
        await page.locator('#asset-'+i).evaluate((im,text)=>{
          const p=document.createElement('p');p.className='status';p.textContent=text;im.parentElement.append(p);
        },(observed.passed?'PASS':'FAIL')+' · '+observed.response.action+' · '+observed.dom.natural_width+'×'+observed.dom.natural_height);
      }catch(error){observed.error=String(error).split('\n')[0];}
      observed.elapsed_ms=Date.now()-start;row.assets.push(observed);
    }
    await page.screenshot({path:path.join(out,'gallery.png'),fullPage:true,animations:'allow'});
    row.screenshot='gallery.png';
    row.passed=row.assets.length===assets.length && row.assets.every(a=>a.passed) && row.failures.length===0;
  }catch(error){row.error=String(error).split('\n')[0];}
  finally{
    if(context)await context.close();
    row.health_after=await health();row.finished_at=new Date().toISOString();
    const wg=row.health_after.wireguard||{};
    row.transport_verified=Number(wg.last_handshake_time_sec)>0 &&
      Number(wg.rx_bytes)>Number((row.health_before.wireguard||{}).rx_bytes||0) &&
      Number(wg.tx_bytes)>Number((row.health_before.wireguard||{}).tx_bytes||0);
    row.passed=row.passed&&row.transport_verified;
    fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(row,null,2)+'\n');
  }
  console.log(JSON.stringify({run_id:run,passed:row.passed,transport_verified:row.transport_verified,
    assets:row.assets.map(a=>({fixture:a.fixture,passed:a.passed,action:a.response?.action,animation_visible:a.animation_visible,error:a.error})),error:row.error}));
  if(!row.passed)process.exitCode=1;
})().catch(e=>{console.error(String(e).split('\n')[0]);process.exitCode=1;});
