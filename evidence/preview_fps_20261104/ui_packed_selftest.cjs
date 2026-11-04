const fs=require('fs'),path=require('path'),assert=require('assert'),crypto=require('crypto');
const {chromium}=require('C:/Users/Makise Aohara/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const root=path.resolve(__dirname,'../..'),html=fs.readFileSync(path.join(root,'tools/page.html'),'utf8');
const fixture=fs.readFileSync(path.join(__dirname,'preview_packet_fixture.bin'));
assert.equal(fixture.subarray(0,4).toString(),'MMTP');
const jsonSize=fixture.readUInt32BE(8),fixtureState=JSON.parse(fixture.subarray(24,24+jsonSize)),pixels=fixture.subarray(24+jsonSize);
assert.equal(pixels.length,9216);
for(let i=0;i<pixels.length;i++)assert.equal(pixels[i],i%256);
function packet(state,raw=pixels,headerSeq=state.tracking.frame_id){
 const json=Buffer.from(JSON.stringify(state)),header=Buffer.from(fixture.subarray(0,24));
 header.writeUInt32BE(json.length,8);header.writeUInt16BE(state.tracking.width,12);header.writeUInt16BE(state.tracking.height,14);
 header.writeUInt32BE(headerSeq,16);header.writeUInt32BE(raw.length,20);return Buffer.concat([header,json,raw]);
}
function clone(v){return JSON.parse(JSON.stringify(v));}
async function instrument(page){
 await page.addInitScript(()=>{
  window.__packedDraws=[];window.__lastPackedRGBA=null;
  const original=CanvasRenderingContext2D.prototype.drawImage;
  CanvasRenderingContext2D.prototype.drawImage=function(...args){
   const result=original.apply(this,args),source=args[0];
   if(this.canvas?.id==='view' && (source instanceof HTMLCanvasElement || source instanceof HTMLImageElement)){
    const entry={at_ms:performance.now(),frame_id:document.getElementById('frame-no')?.textContent,
     stamp:document.getElementById('stamp')?.textContent,source_type:source.constructor.name,geometry:args.slice(1),
     source_width:source.naturalWidth||source.width,source_height:source.naturalHeight||source.height};
    if(source instanceof HTMLCanvasElement){window.__lastPackedRGBA=Array.from(source.getContext('2d').getImageData(0,0,source.width,source.height).data);}
    window.__packedDraws.push(entry);
   }return result;
  };
 });
}
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,args:['--no-proxy-server']});
 const checks=[],errors=[];let packedRequests=0,stateRequests=0,imageRequests=0,mode='fixture',nextSeq=12;
 try{
  const page=await browser.newPage({viewport:{width:1450,height:1050}});await instrument(page);page.on('pageerror',e=>errors.push(String(e)));
  await page.route('http://mmt.test/**',async route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/')return route.fulfill({contentType:'text/html; charset=utf-8',body:html});
   if(u.pathname==='/api/preview'){
    packedRequests++;
    if(mode==='fixture')return route.fulfill({contentType:'application/x-mmt-preview',body:fixture});
    const state=clone(fixtureState);state.tracking.source='board_telemetry';state.tracking.timestamp_ms=nextSeq*200;
    if(mode==='advance')nextSeq++;
    state.tracking.frame_id=nextSeq;state.tracking.timestamp_ms=nextSeq*200;
    state.tracking.aspect_width=1920;state.tracking.aspect_height=1080;
    return route.fulfill({contentType:'application/x-mmt-preview',body:packet(state,pixels,mode==='mismatch'?nextSeq+1:nextSeq)});
   }
   if(u.pathname==='/api/state'){stateRequests++;return route.fulfill({status:500,body:'unexpected fallback'})}
   if(u.pathname.includes('frame.png')){imageRequests++;return route.fulfill({status:500,body:'unexpected separate image request'})}
   return route.fulfill({status:404,body:'not found'});
  });
  await page.goto('http://mmt.test/',{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>window.__packedDraws.length>=1);
  assert.equal(await page.locator('#frame-no').innerText(),'12');
  let draw=await page.evaluate(()=>window.__packedDraws.at(-1));
  assert.equal(draw.source_type,'HTMLCanvasElement');assert.deepStrictEqual(draw.geometry,[210,0,540,540]);
  const rgba=await page.evaluate(()=>window.__lastPackedRGBA);assert.equal(rgba.length,pixels.length*4);
  for(let i=0;i<pixels.length;i++)assert.deepStrictEqual(rgba.slice(i*4,i*4+4),[pixels[i],pixels[i],pixels[i],255]);
  checks.push('real C fixture is consumed by the browser in one response','all 9216 rendered Gray8 pixels and alpha match the C fixture exactly','square fixture has correct 960x540 letterbox geometry');
  await page.waitForFunction(()=>window.__packedDraws.length>=8);
  let count=await page.evaluate(()=>window.__packedDraws.length);
  let fpsText=await page.locator('#video-fps').innerText(),fps=Number(fpsText.match(/([\d.]+) FPS/)?.[1]);
  assert(Number.isFinite(fps)&&fps<=1.1,{fpsText,count});
  assert.equal(new Set((await page.evaluate(()=>window.__packedDraws)).map(d=>d.frame_id)).size,1);
  checks.push('repeated packed responses repaint but are excluded from unique capture FPS');
  mode='advance';
  await page.waitForFunction(()=>Number(document.getElementById('frame-no').textContent)>=16);
  draw=await page.evaluate(()=>window.__packedDraws.at(-1));assert.deepStrictEqual(draw.geometry,[0,0,960,540]);
  assert.equal(await page.evaluate(()=>MMT_UI.viewRect().w/MMT_UI.viewRect().h),16/9);
  assert.equal(stateRequests,0);assert.equal(imageRequests,0);
  checks.push('physical 16:9 aspect is restored from packed metadata','packed mode does not request a second state or PNG');
  mode='hold';await page.waitForTimeout(220);
  fpsText=await page.locator('#video-fps').innerText();fps=Number(fpsText.match(/([\d.]+) FPS/)?.[1]);assert(fps>1.1,{fpsText});
  checks.push('new capture IDs increase measured unique frame FPS');
  const bad=Buffer.from(fixture);bad.writeUInt32BE(13,16);
  const direct=await page.evaluate(base64=>{
   try{MMT_UI.decodePreview(Uint8Array.from(atob(base64),c=>c.charCodeAt(0)).buffer);return {accepted:true}}
   catch(e){return {accepted:false,error:String(e)}}
  },bad.toString('base64'));
  assert.equal(direct.accepted,false);assert.match(direct.error,/快照不匹配/);
  const truncated=await page.evaluate(base64=>{
   try{MMT_UI.decodePreview(Uint8Array.from(atob(base64),c=>c.charCodeAt(0)).buffer);return false}catch(e){return true}
  },fixture.subarray(0,fixture.length-1).toString('base64'));assert(truncated);
  checks.push('mismatched packet/JSON capture IDs and truncated payload are rejected');
  mode='mismatch';await page.waitForFunction(()=>document.getElementById('message').textContent.includes('快照不匹配'));
  count=await page.evaluate(()=>window.__packedDraws.length);const lastGood=await page.locator('#frame-no').innerText();
  await page.waitForTimeout(300);assert.equal(await page.evaluate(()=>window.__packedDraws.length),count);assert.equal(await page.locator('#frame-no').innerText(),lastGood);
  assert.equal(await page.locator('#video-fps').innerText(),'画面已暂停');
  checks.push('malformed packet never replaces the last complete displayed image');
  await page.screenshot({path:path.join(__dirname,'ui_packed_mismatch.png'),fullPage:true});await page.close();
  const legacy=await browser.newPage({viewport:{width:1450,height:1050}});await instrument(legacy);legacy.on('pageerror',e=>errors.push(String(e)));
  let legacyProbe=0,legacyState=0,legacyImages=0;
  const oldState=clone(fixtureState);oldState.tracking.frame_id=44;oldState.tracking.timestamp_ms=8800;oldState.tracking.source='board_telemetry';oldState.tracking.frame_url='/frame.png?seq=44';oldState.tracking.aspect_width=1920;oldState.tracking.aspect_height=1080;
  await legacy.route('http://legacy.test/**',async route=>{
   const u=new URL(route.request().url());
   if(u.pathname==='/')return route.fulfill({contentType:'text/html; charset=utf-8',body:html});
   if(u.pathname==='/api/preview'){legacyProbe++;return route.fulfill({status:404,body:'not found'})}
   if(u.pathname==='/api/state'){legacyState++;return route.fulfill({contentType:'application/json',body:JSON.stringify(oldState)})}
   if(u.pathname==='/frame.png'){legacyImages++;return route.fulfill({contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" fill="#808080"/></svg>'})}
   return route.fulfill({status:404,body:'not found'});
  });
  await legacy.goto('http://legacy.test/',{waitUntil:'domcontentloaded'});await legacy.waitForFunction(()=>window.__packedDraws.length>=3);
  assert.equal(await legacy.locator('#frame-no').innerText(),'44');assert.equal(legacyProbe,1);assert(legacyState>=3);assert(legacyImages>=1);
  assert.equal(await legacy.locator('#empty').evaluate(e=>e.style.display),'none');
  assert.equal((await legacy.evaluate(()=>window.__packedDraws.at(-1))).source_type,'HTMLImageElement');
  checks.push('legacy 404 probes packed support once then displays state/PNG normally');
  await legacy.screenshot({path:path.join(__dirname,'ui_packed_legacy_fallback.png'),fullPage:true});await legacy.close();
  assert.deepStrictEqual(errors,[]);checks.push('no uncaught JavaScript errors');
  const result={passed:true,fixture_sha256:crypto.createHash('sha256').update(fixture).digest('hex'),fixture_bytes:fixture.length,checked_pixels:pixels.length,packed_requests:packedRequests,state_requests_in_packed_mode:stateRequests,separate_images_in_packed_mode:imageRequests,checks};
  fs.writeFileSync(path.join(__dirname,'ui_packed_selftest.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
