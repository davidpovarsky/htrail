'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');

const root = process.env.PURELINE_LAB_ROOT || '/Users/m1/builds/pureline-wireguard-lab-20261127';
const stamp = process.env.PURELINE_BROWSER_RUN || 'chromium-rendered-v1';
const out = path.join(root, 'evidence', stamp);
const profile = path.join(root, 'browser-runtime', 'profiles', stamp);
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(profile, { recursive: true });
const cert = new crypto.X509Certificate(fs.readFileSync(path.join(root, 'mitmproxy-ca-cert.pem')));
const spki = crypto.createHash('sha256').update(cert.publicKey.export({ type: 'spki', format: 'der' })).digest('base64');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'gallery', 'manifest.json'), 'utf8'));
const selectedPages = new Set((process.env.PURELINE_BROWSER_PAGES || "").split(",").filter(Boolean));
const pages = [
  ...['allow','block','mixed','mixed-2','objects','groups','thumbnails','thumbnails-2','svg','highres'].map(name => ({
    id: name, url: 'http://127.0.0.1:18524/' + name + '.html', kind: 'fixture-gallery',
    expected: Object.fromEntries(manifest.pages[name].map(row => [row.id, row.expected]))
  })),
  { id: 'wikipedia-nature', url: 'https://en.wikipedia.org/wiki/Nature', kind: 'public-page' },
  { id: 'wikipedia-einstein', url: 'https://en.wikipedia.org/wiki/Albert_Einstein', kind: 'public-page' },
  { id: 'wikipedia-meir', url: 'https://en.wikipedia.org/wiki/Golda_Meir', kind: 'public-page' },
].filter(page => selectedPages.size === 0 || selectedPages.has(page.id));
function write(name, value) { fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n'); }
async function health() {
  try { return await (await fetch('http://127.0.0.1:18520/__pureline_lab_health', { signal: AbortSignal.timeout(5000) })).json(); }
  catch (e) { return { error: String(e) }; }
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const clean = url => {
  try {
    const u = new URL(url), query = new URLSearchParams();
    if (!['http:','https:'].includes(u.protocol)) return u.protocol + 'sha256:' + crypto.createHash('sha256').update(url).digest('hex');
    const allowed = new Set(['pureline_qa','pureline_rewrite_probe','utm_source','utm_campaign','utm_content','modules','image','format','lang','skin','version','debug','only','type','variant']);
    for (const [key,value] of u.searchParams) if (allowed.has(key)) query.append(key,value);
    return u.origin + u.pathname + (query.size ? '?' + query.toString() : '');
  } catch { return url; }
};
(async () => {
  const started = new Date().toISOString();
  const summary = {
    run_id: stamp, started_at: started, platform: process.platform, arch: process.arch,
    playwright: require('playwright/package.json').version,
    proxy: 'http://127.0.0.1:18520', local_html_bypass: ['127.0.0.1','localhost'],
    trust: { mode: 'Chromium SPKI allowlist only', ca_spki_sha256_base64: spki, ignoreHTTPSErrors: false, global_trust_changes: false },
    backend_revision: process.env.PURELINE_BACKEND_REVISION || 'unrecorded',
    fresh_persistent_profile: profile, route: 'Chromium HTTP CONNECT -> official WireGuard userspace netstack -> SSH-carried UDP -> isolated Oracle WireGuard mitmproxy -> Pureline CPU candidate -> public HTTPS origin',
    limitations: ['Per-browser proxy; not system VPN or iOS NetworkExtension', 'WireGuard outer UDP carried over SSH TCP; internet UDP reachability not tested', 'Public page outcomes are coverage evidence, not independent labelled accuracy samples'],
    health_before: await health(), pages: []
  };
  const context = await chromium.launchPersistentContext(profile, {
    headless: true, proxy: { server: summary.proxy, bypass: '127.0.0.1,localhost' },
    args: ['--ignore-certificate-errors-spki-list=' + spki, '--disable-quic'],
    ignoreHTTPSErrors: false, viewport: { width: 1365, height: 1000 },
    acceptDownloads: false
  });
  summary.browser = context.browser().version();
  write('summary.json', summary);
  try {
    for (const target of pages) {
      const page = await context.newPage();
      const start = Date.now(), responses = [], failed = [], errors = [], pending = [];
      const network = {}, cacheRequestIds = new Set(), requestedURLs = new Set(), imagesInFlight = new Set();
      let lastImageRequestAt = 0;
      page.on('request', request => { requestedURLs.add(clean(request.url())); if (request.resourceType() === 'image') { imagesInFlight.add(request); lastImageRequestAt = Date.now(); } });
      page.on('requestfinished', request => imagesInFlight.delete(request));
      page.on('requestfailed', request => imagesInFlight.delete(request));
      const cdp = await context.newCDPSession(page);
      await cdp.send('Network.enable');
      cdp.on('Network.responseReceived', e => {
        network[e.requestId] = { url: clean(e.response.url), resourceType: e.type,
          status: e.response.status, mimeType: e.response.mimeType,
          servedFromCache: cacheRequestIds.has(e.requestId), fromDiskCache: !!e.response.fromDiskCache, fromServiceWorker: !!e.response.fromServiceWorker,
          protocol: e.response.protocol, encodedDataLength: e.response.encodedDataLength || 0 };
      });
      cdp.on('Network.requestServedFromCache', e => { cacheRequestIds.add(e.requestId); if (network[e.requestId]) network[e.requestId].servedFromCache = true; });
      cdp.on('Network.loadingFinished', e => { if (network[e.requestId]) network[e.requestId].encodedDataLength = e.encodedDataLength; });
      page.on('pageerror', e => errors.push(String(e).slice(0, 300)));
      page.on('requestfailed', request => failed.push({url: clean(request.url()), type: request.resourceType(), error: request.failure()?.errorText}));
      page.on('response', response => {
        const task = (async () => {
          const type = response.request().resourceType();
          const h = await response.allHeaders();
          if (type !== 'image' && type !== 'document' && !h['x-local-image-filter']) return;
          const item = {
            url: clean(response.url()), resourceType: type, status: response.status(),
            contentType: h['content-type'] || '', contentEncoding: h['content-encoding'] || null,
            contentLength: h['content-length'] || null, cacheControl: h['cache-control'] || null, action: h['x-local-image-filter'] || null,
            reason: h['x-local-image-filter-reason'] || null, presentation: h['x-local-image-filter-presentation'] || null,
            labOrigin: h['x-pureline-lab-origin'] || null, sourceSha256: h['x-pureline-lab-source-sha256'] || null, cache: h['x-local-image-filter-cache'] || null,
            elapsed_ms: Date.now() - start
          };
          if (type === 'image') {
            try {
              const body = await response.body();
              item.body_bytes = body.length;
              item.body_sha256 = crypto.createHash('sha256').update(body).digest('hex');
            } catch (e) { item.body_error = String(e).slice(0, 180); }
          }
          if (type === 'document' && response.url().startsWith('https:')) {
            try { item.tls = await response.securityDetails(); } catch {}
          }
          responses.push(item);
        })();
        pending.push(task);
      });
      let nav = null, navError = null;
      try {
        const res = await page.goto(target.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
        nav = res ? res.status() : null;
      } catch (e) { navError = String(e).split('\n')[0]; }
      if (target.kind === 'public-page') {
        for (let i=0; i<8; i++) {
          await page.evaluate(() => window.scrollBy(0, Math.max(600, window.innerHeight * 0.85))).catch(()=>{});
          await sleep(700);
        }
      }
      let imagesSettled = false;
      if (target.kind === 'public-page') {
        const deadline = Date.now() + 90000;
        while (Date.now() < deadline && (imagesInFlight.size > 0 || Date.now() - lastImageRequestAt < 1500)) await sleep(250);
        imagesSettled = imagesInFlight.size === 0;
      } else {
        try {
          await page.waitForFunction(() => Array.from(document.images).every(i => i.complete), null, { timeout: 90000 });
          imagesSettled = true;
        } catch {}
      }
      await sleep(1200);
      const scrolledY = await page.evaluate(() => window.scrollY).catch(()=>0);
      let scrolledScreenshot = null;
      if (target.kind === 'public-page') {
        try { scrolledScreenshot = target.id + '-scrolled.png'; await page.screenshot({ path: path.join(out, scrolledScreenshot), timeout: 30000 }); }
        catch { scrolledScreenshot = null; }
      }
      await page.evaluate(() => window.scrollTo(0,0)).catch(()=>{});
      await Promise.allSettled([...pending]);
      const dom = await page.evaluate(() => ({
        title: document.title, url: location.href,
        image_count: document.images.length,
        images: Array.from(document.images).map(img => ({
          url: img.currentSrc || img.src, alt: img.alt, complete: img.complete,
          naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight,
          renderedWidth: Math.round(img.getBoundingClientRect().width),
          renderedHeight: Math.round(img.getBoundingClientRect().height), loading: img.loading,
          cssBackground: getComputedStyle(img).backgroundColor
        })),
        load_status_text: document.querySelector('#loaded')?.textContent || null,
        body_height: document.body.scrollHeight
      })).catch(e => ({error:String(e)}));
      if (dom.images) for (const img of dom.images) {
        img.url = clean(img.url);
        img.expected = target.expected?.[img.alt] || null;
        const response = [...responses].reverse().find(r => r.url === img.url && r.resourceType === 'image');
        img.observed_action = response?.action || null;
        img.http_status = response?.status || null;
        img.request_observed = requestedURLs.has(img.url);
        img.response_observed = !!response;
        img.inline_source = img.url.startsWith('data:') || img.url.startsWith('blob:');
        img.decoded = img.complete && img.naturalWidth > 0;
        img.policy_match = img.expected && img.decoded && img.observed_action
          ? (img.expected === 'allow' ? img.observed_action === 'allow' : ['blur','block'].includes(img.observed_action)) : null;
      }
      const shot = target.id + '.png';
      let screenshotError = null;
      try { await page.screenshot({ path: path.join(out, shot), fullPage: target.kind === 'fixture-gallery', timeout: 30000 }); }
      catch (e) { screenshotError = String(e).split('\n')[0]; }
      const item = {
        id: target.id, kind: target.kind, requested_url: target.url, navigation_status: nav, navigation_error: navError,
        elapsed_ms: Date.now()-start, all_requested_images_settled: imagesSettled, all_dom_images_settled: dom.images?.every(i=>i.complete) || false, screenshot: screenshotError ? null : shot,
        screenshot_error: screenshotError, scrolled_screenshot: scrolledScreenshot, scroll_y_before_return_to_top: scrolledY, dom, responses, failed_requests: failed, javascript_errors: errors,
        network: Object.values(network), health_after: await health()
      };
      item.counts = {
        dom_images: dom.images?.length || 0, decoded_images: dom.images?.filter(i=>i.decoded).length || 0,
        decoded_inline_images: dom.images?.filter(i=>i.inline_source && i.decoded).length || 0,
        attempted_decode_failures: dom.images?.filter(i=>i.response_observed && i.complete && !i.decoded).length || 0,
        pending_requested_images: dom.images?.filter(i=>i.request_observed && !i.complete).length || 0,
        pending_image_requests_at_capture: imagesInFlight.size,
        unrequested_images: dom.images?.filter(i=>!i.request_observed && !i.decoded).length || 0,
        browser_cached_responses: Object.values(network).filter(i=>i.fromDiskCache || i.servedFromCache || i.fromServiceWorker).length,
        image_network_responses: responses.filter(i=>i.resourceType==='image').length,
        actions: responses.filter(i=>i.resourceType==='image').reduce((a,i)=>(a[i.action||'unclassified']=(a[i.action||'unclassified']||0)+1,a),{}),
        labelled_matches: dom.images?.filter(i=>i.policy_match===true).length || 0,
        labelled_mismatches: dom.images?.filter(i=>i.policy_match===false).length || 0,
        labelled_unresolved: dom.images?.filter(i=>i.expected && i.policy_match===null).length || 0,
        failed_requests: failed.length
      };
      write(target.id+'.json', item);
      summary.pages.push({id:item.id,kind:item.kind,status:nav,error:navError,elapsed_ms:item.elapsed_ms,counts:item.counts,screenshot:item.screenshot});
      write('summary.json', summary);
      console.log(JSON.stringify({id:item.id,elapsed_ms:item.elapsed_ms,counts:item.counts}));
      await page.close();
    }
  } finally {
    summary.finished_at = new Date().toISOString();
    summary.health_after = await health();
    write('summary.json', summary);
    await context.close();
  }
})().catch(e => { console.error(e.stack || String(e)); process.exitCode = 1; });
