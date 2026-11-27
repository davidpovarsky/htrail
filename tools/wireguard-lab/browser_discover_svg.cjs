'use strict';
// URL inventory only. Images are deliberately aborted; never acceptance evidence.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');
const root = process.env.PURELINE_LAB_ROOT || '/Users/m1/builds/pureline-wireguard-lab-20261127';
const cert = new crypto.X509Certificate(fs.readFileSync(path.join(root, 'mitmproxy-ca-cert.pem')));
const pin = crypto.createHash('sha256').update(cert.publicKey.export({type:'spki',format:'der'})).digest('base64');
(async()=>{
  const context = await chromium.launchPersistentContext(path.join(root,'browser-runtime/profiles/nature-url-discovery'),{headless:true,args:['--ignore-certificate-errors-spki-list='+pin,'--disable-quic'],proxy:{server:'http://127.0.0.1:18520',bypass:'127.0.0.1,localhost'},ignoreHTTPSErrors:false,viewport:{width:1365,height:1000}});
  const found = new Set();
  await context.route('**/*',async route=>{
    if(route.request().resourceType()==='image'){found.add(route.request().url());await route.abort('aborted');}
    else await route.continue();
  });
  const page = await context.newPage();
  try {
    await page.goto('https://en.wikipedia.org/wiki/Nature',{waitUntil:'domcontentloaded',timeout:45000});
    for(let i=0;i<8;i++){await page.evaluate(()=>scrollBy(0,850));await new Promise(r=>setTimeout(r,500));}
    await new Promise(r=>setTimeout(r,1000));
    const urls=[...found].sort();
    const svg=urls.filter(u=>{const x=new URL(u);return /\.svg$/.test(x.pathname)|| (x.pathname==='/w/load.php'&&x.searchParams.has('image'));});
    const evidence={purpose:'URL inventory only; image fetches aborted; not rendering or filtering acceptance evidence',page:page.url(),captured_at:new Date().toISOString(),image_urls:urls,svg_candidate_urls:svg};
    fs.writeFileSync(path.join(root,'evidence/nature-svg-urls.json'),JSON.stringify(evidence,null,2)+'\n');
    console.log(JSON.stringify({images:urls.length,svg_candidates:svg.length}));
  } finally {await context.close();}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
