'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { chromium } = require('playwright');

const root = process.env.PURELINE_LAB_ROOT || '/Users/m1/builds/pureline-wireguard-lab-20261127';
const run = process.env.PURELINE_BROWSER_RUN || 'chromium-wikisource-v4';
const revision = process.env.PURELINE_BACKEND_REVISION;
if (!revision) throw new Error('A frozen backend revision is required.');
const out = path.join(root, 'evidence', run);
const profile = path.join(root, 'browser-runtime', 'profiles', run);
if (fs.existsSync(profile)) throw new Error('Use a new run ID and browser profile.');
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(profile, { recursive: true });
const cert = new crypto.X509Certificate(fs.readFileSync(path.join(root, 'mitmproxy-ca-cert.pem')));
const spki = crypto.createHash('sha256').update(cert.publicKey.export({ type: 'spki', format: 'der' })).digest('base64');
const url = 'https://upload.wikimedia.org/wikipedia/commons/4/4c/Wikisource-logo.svg';
const expectedSourceSha256 = '211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95';

async function health() {
  try { return await (await fetch('http://127.0.0.1:18520/__pureline_lab_health', { signal: AbortSignal.timeout(5000) })).json(); }
  catch { return { error: 'health_unavailable' }; }
}
function save(row) { fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(row, null, 2) + '\n'); }

(async () => {
  const row = {
    run_id: run, started_at: new Date().toISOString(), backend_revision: revision,
    platform: process.platform, arch: process.arch, playwright: require('playwright/package.json').version,
    route: 'Chromium image request -> explicit HTTP CONNECT -> real WireGuard -> isolated Oracle frozen filter -> public HTTPS origin',
    url, expected: 'allow', expected_original_sha256: expectedSourceSha256,
    proxy: 'http://127.0.0.1:18520', fresh_profile: profile,
    trust: { ignoreHTTPSErrors: false, mode: 'Lab CA SPKI only', ca_spki_sha256_base64: spki, global_trust_changes: false },
    scope: 'One actual rendered public SVG asset, not a complete Einstein-page rerun or a new accuracy sample.',
    health_before: await health(), failures: [], passed: false
  };
  let context;
  const start = Date.now();
  try {
    context = await chromium.launchPersistentContext(profile, {
      headless: true, proxy: { server: row.proxy, bypass: '127.0.0.1,localhost' },
      args: ['--ignore-certificate-errors-spki-list=' + spki, '--disable-quic'],
      ignoreHTTPSErrors: false, viewport: { width: 900, height: 760 }, acceptDownloads: false
    });
    row.browser = context.browser().version();
    const page = await context.newPage();
    page.on('requestfailed', request => {
      if (request.url() === url) row.failures.push({ error: request.failure()?.errorText || 'request_failed' });
    });
    const observedResponse = page.waitForResponse(response => response.url() === url, { timeout: 45000 });
    await page.setContent('<!doctype html><meta charset="utf-8"><title>Pureline public SVG verification</title><style>body{font:18px system-ui;margin:36px;background:#f4f7fb;color:#17243a}h1{font-size:25px}figure{padding:24px;background:white;border:1px solid #ccd7e6;border-radius:12px;display:inline-block}img{display:block;max-width:500px;max-height:510px}figcaption{margin-top:18px}</style><h1>Pureline: public Wikisource SVG</h1><p>Real public image request through the isolated WireGuard filter.</p><figure><img id="asset" alt="Wikisource logo" src="' + url + '"><figcaption>Expected: allow the original benign logo.</figcaption></figure>', { waitUntil: 'domcontentloaded' });
    const response = await observedResponse;
    const headers = await response.allHeaders();
    const body = await response.body();
    row.response = {
      status: response.status(), content_type: headers['content-type'] || null,
      content_encoding: headers['content-encoding'] || null, declared_content_length: headers['content-length'] || null,
      action: headers['x-local-image-filter'] || null, reason: headers['x-local-image-filter-reason'] || null,
      presentation: headers['x-local-image-filter-presentation'] || null,
      policy_exception: headers['x-local-image-filter-policy-exception'] || null,
      decoded_body_bytes: body.length, decoded_body_sha256: crypto.createHash('sha256').update(body).digest('hex')
    };
    await page.waitForFunction(() => {
      const img = document.getElementById('asset');
      return img.complete && img.naturalWidth > 0 && img.naturalHeight > 0;
    }, null, { timeout: 45000 });
    row.dom = await page.evaluate(async () => {
      const img = document.getElementById('asset');
      await img.decode();
      return { complete: img.complete, natural_width: img.naturalWidth, natural_height: img.naturalHeight, decode_resolved: true };
    });
    await page.screenshot({ path: path.join(out, 'wikisource.png'), fullPage: true });
    row.screenshot = 'wikisource.png';
    row.passed = row.response.status === 200 && row.response.action === 'allow' &&
      row.response.decoded_body_sha256 === expectedSourceSha256 &&
      row.response.presentation === null && row.response.policy_exception === null &&
      row.dom.decode_resolved && row.failures.length === 0;
  } catch (error) {
    row.error = String(error).split('\n')[0];
  } finally {
    if (context) await context.close();
    row.elapsed_ms = Date.now() - start;
    row.finished_at = new Date().toISOString();
    row.health_after = await health();
    save(row);
  }
  console.log(JSON.stringify({ run_id: run, passed: row.passed, elapsed_ms: row.elapsed_ms, response: row.response, dom: row.dom, error: row.error }));
  if (!row.passed) process.exitCode = 1;
})().catch(error => { console.error(String(error).split('\n')[0]); process.exitCode = 1; });
