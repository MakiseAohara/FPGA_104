const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require('C:/Users/Makise Aohara/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
const root=path.resolve(__dirname,'../..'),html=fs.readFileSync(path.join(root,'tools/page.html'),'utf8');
const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true});
const page=await browser.newPage({viewport:{width:1450,height:1100},deviceScaleFactor:1});
let faults=[],posts=[],mode='offline',requestCount=0;
page.on('pageerror',e=>faults.push(String(e)));
const obj={f:7,sht:250,rh:625,body:312,inf_hz:2,paused:0,events:[],tracking:{schema:1,source:'offline_synthetic',frame_id:7,timestamp_ms:1400,sample_ms:400,time_step_ms:200,horizon_ms:400,horizon_steps:2,width:96,height:96,roi:[24,24,72,72],frame_url:'/replay/frame.png?seq=7',tracks:[{id:1,bbox:[15,20,32,60],center:[23,40],velocity_q4:[32,0],prediction:[27,40],future:[[25,40],[27,40]],history:[[15,40],[19,40],[23,40]],confirmed:true,visible:true,misses:0,hits:8,state:'observed',supported:true,eta_steps:2,eta_ms:400},{id:2,bbox:[56,28,72,65],center:[64,46],velocity_q4:[-16,0],prediction:[62,46],future:[[63,46],[62,46]],history:[[70,46],[67,46],[64,46]],confirmed:true,visible:false,misses:1,hits:5,state:'coasting',supported:false,eta_steps:-1,eta_ms:-1}],baseline_tracks:[],prewarn:{active:true,id:1,eta_steps:2,eta_ms:400,action:'wake_inference'},metrics:{id_switches:0}},replay:{enabled:true,scenario:'cross',scenarios:[{id:'cross',name:'双目标交叉',source:'offline_synthetic',frames:40},{id:'occlusion',name:'短时遮挡',source:'offline_synthetic',frames:25}],index:7,total:40,playing:true,fps:5},evaluation:{synthetic:{id_switches:0}}};
const svg='<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" fill="#263b50"/><rect x="15" y="20" width="17" height="40" fill="#647d93"/><rect x="56" y="28" width="16" height="37" fill="#465b70"/></svg>';
await page.route('http://mmt.test/**',async route=>{
const u=new URL(route.request().url());
if(u.pathname==='/')return route.fulfill({contentType:'text/html; charset=utf-8',body:html});
if(u.pathname==='/api/state'){requestCount++;return route.fulfill({contentType:'application/json',body:JSON.stringify(mode==='offline'?obj:{f:99,sht:249,rh:628,body:257,link:'串口+UDP',events:[]})})}
if(u.pathname==='/api/replay'){const d=route.request().postDataJSON();posts.push(d);Object.assign(obj.replay,d);if(d.scenario==='occlusion'){obj.replay.total=25;obj.replay.index=d.index||0}return route.fulfill({contentType:'application/json',body:'{"ok":true}'})}
if(u.pathname==='/api/metrics')return route.fulfill({contentType:'application/json',body:'{"basis":"受控合成真值","prediction_mae_px":1.2}'});
return route.fulfill({contentType:'image/svg+xml',body:svg});
});
await page.goto('http://mmt.test/');await page.waitForFunction(()=>document.getElementById('observed').textContent==='1');
assert.equal(await page.locator('#coasting').innerText(),'1');assert.match(await page.locator('#source').innerText(),/离线.*合成/);assert.match(await page.locator('#horizon').innerText(),/0.4/);assert.match(await page.locator('#tracks').innerText(),/10\.0/);assert.match(await page.locator('#warning').innerText(),/模拟提前唤醒/);
let r=await page.evaluate(()=>MMT_UI.fitRect(96,96));assert.deepStrictEqual(r,{x:210,y:0,w:540,h:540});r=await page.evaluate(()=>MMT_UI.fitRect(48,27));assert.deepStrictEqual(r,{x:0,y:0,w:960,h:540});assert.equal(await page.evaluate(()=>MMT_UI.speed({velocity_q4:[32,0]},{time_step_ms:200,sample_ms:400})),10);
await page.evaluate(state=>{state.tracking.aspect_width=1920;state.tracking.aspect_height=1080;MMT_UI.show(state)},obj);assert.deepStrictEqual(await page.evaluate(()=>MMT_UI.viewRect()),{x:0,y:0,w:960,h:540});
await page.evaluate(state=>{state.tracking.people_count=2;MMT_UI.show(state)},obj);assert.equal(await page.locator('#observed').innerText(),'2');
await page.evaluate(state=>{state.tracking.people_count=0;state.connected=false;MMT_UI.show(state)},obj);assert.equal(await page.locator('#observed').innerText(),'--');assert.match(await page.locator('#warning').innerText(),/暂停/);
await page.evaluate(state=>MMT_UI.show(state),obj);
await page.locator('#fullscreen').click();await page.waitForFunction(()=>document.fullscreenElement?.id==='screen');await page.evaluate(()=>document.exitFullscreen());
await page.locator('tr[data-id="1"]').click();assert.match(await page.locator('#detail').innerText(),/目标 ID 1/);
await page.locator('#play').click();await page.waitForFunction(()=>document.getElementById('play').textContent==='播放');assert(posts.some(d=>d.playing===false));
await page.locator('#scenario').selectOption('occlusion');await page.waitForFunction(()=>document.getElementById('position').textContent==='1 / 25');
await page.locator('#seek').evaluate(el=>{el.value='12';el.dispatchEvent(new Event('input'));el.dispatchEvent(new Event('change'))});await page.waitForFunction(()=>document.getElementById('position').textContent==='13 / 25');assert(posts.some(d=>d.index===12&&d.playing===false));
await page.locator('#evaldetails summary').click();await page.waitForFunction(()=>document.getElementById('evaluation').textContent.includes('prediction_mae_px'));
await page.screenshot({path:path.join(__dirname,'ui_offline_desktop.png'),fullPage:true});
await page.setViewportSize({width:420,height:950});await page.screenshot({path:path.join(__dirname,'ui_offline_mobile.png'),fullPage:true});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2));
mode='legacy';await page.waitForFunction(()=>document.getElementById('warning').textContent.includes('当前固件未提供轨迹'));assert.equal(await page.locator('#observed').innerText(),'--');assert(await page.locator('#replay').isHidden());assert.equal(await page.locator('#tracks tr[data-id]').count(),0);
await page.screenshot({path:path.join(__dirname,'ui_legacy_compatibility.png'),fullPage:true});
assert.deepStrictEqual(faults,[]);const result={passed:true,page_bytes:Buffer.byteLength(html),checks:['authoritative 2-person count','stale count withheld','16:9 camera coordinate mapping','fullscreen','observed/coasting separated','velocity uses canonical time step','square/wide image contain mapping','offline provenance and simulated action','ID selection','pause/scenario/seek controls','metrics endpoint','mobile overflow','legacy firmware without invented tracks','no JavaScript errors'],requests:requestCount,posts};fs.writeFileSync(path.join(__dirname,'ui_selftest.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
