'use strict';
// Negative control: the lab CA must not be trusted without the scoped SPKI exception.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const root = process.env.PURELINE_LAB_ROOT || '/Users/m1/builds/pureline-wireguard-lab-20261127';
(async()=>{
  const context=await chromium.launchPersistentContext(path.join(root,'browser-runtime/profiles/untrusted-ca-negative-control'),{
    headless:true,proxy:{server:'http://127.0.0.1:18520',bypass:'127.0.0.1,localhost'},
    ignoreHTTPSErrors:false,args:['--disable-quic']
  });
  const result={purpose:'Negative TLS trust control; no SPKI allowlist and no certificate bypass',started_at:new Date().toISOString(),url:'https://example.com',ignoreHTTPSErrors:false,proxy:'http://127.0.0.1:18520'};
  try {
    const page=await context.newPage();
    try {const response=await page.goto(result.url,{waitUntil:'domcontentloaded',timeout:25000});result.status=response?.status();result.error=null;}
    catch(e){result.error=String(e).split('\n')[0];}
    result.passed=result.error?.includes('ERR_CERT_AUTHORITY_INVALID')===true;
    result.finished_at=new Date().toISOString();
    fs.writeFileSync(path.join(root,'evidence/browser-trust-negative-control.json'),JSON.stringify(result,null,2)+'\n');
    console.log(JSON.stringify(result));
    if(!result.passed)process.exitCode=1;
  } finally {await context.close();}
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
