const fs = require('fs'), path = require('path'), crypto = require('crypto');
const { chromium } = require('C:/Users/Makise Aohara/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const outIndex=process.argv.indexOf('--out');
const out=outIndex>=0?path.resolve(process.argv[outIndex+1]):__dirname;
fs.mkdirSync(out,{recursive:true});
function percentile(values, p) { if (!values.length) return null; const a=[...values].sort((x,y)=>x-y); return a[Math.min(a.length-1,Math.floor(p*a.length))]; }
function summarize(name, duration, displays, responses, errors, wall_ms) {
  const ids = [], contents = [], uniqueDisplays=[];
  for (const e of displays) if (!ids.includes(e.frame_id)) { ids.push(e.frame_id); uniqueDisplays.push(e); }
  for (const r of responses) if (r.kind==='image' && r.sha256 && !contents.includes(r.sha256)) contents.push(r.sha256);
  const imageTimes=responses.filter(r=>r.kind==='image' && r.status===200).map(r=>r.total_ms).filter(v=>Number.isFinite(v) && v>=0);
  const stateTimes=responses.filter(r=>r.kind==='state' && r.status===200).map(r=>r.total_ms).filter(v=>Number.isFinite(v) && v>=0);
  const intervals=uniqueDisplays.slice(1).map((e,i)=>e.now_ms-uniqueDisplays[i].now_ms);
  return {name, measurement_seconds:duration, wall_ms, draw_completions:displays.length, unique_frame_ids:ids.length,
    repeated_draws:displays.length-ids.length, repeat_fraction:displays.length?(displays.length-ids.length)/displays.length:null,
    unique_frames_per_window_second:ids.length/duration,
    steady_unique_fps:uniqueDisplays.length>1?(uniqueDisplays.length-1)*1000/(uniqueDisplays.at(-1).now_ms-uniqueDisplays[0].now_ms):null,
    unique_frame_ids_displayed:ids, unique_png_contents:contents.length,
    image_total_ms:{median:percentile(imageTimes,.5),p95:percentile(imageTimes,.95)},
    state_total_ms:{median:percentile(stateTimes,.5),p95:percentile(stateTimes,.95)},
    inter_unique_frame_ms:{median:percentile(intervals,.5),p95:percentile(intervals,.95)},
    errors, responses_failed:responses.filter(r=>r.status!==200 || r.error).length};
}
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,args:['--no-proxy-server']});
 const result={method:'Edge canvas drawImage completion; unique snapshot IDs, not page timers', captured_at:new Date().toISOString(), pages:[]};
 for (const [name,base,duration] of [['pc','http://169.254.47.62:8090',20],['board','http://169.254.47.63',10]]) {
  const page=await browser.newPage({viewport:{width:1450,height:1050}}), responses=[],errors=[],pending=new Set();
  await page.addInitScript(()=>{
   window.__fpsDraws=[];
   const original=CanvasRenderingContext2D.prototype.drawImage;
   CanvasRenderingContext2D.prototype.drawImage=function(...args){
    const r=original.apply(this,args);const source=args[0];
    if(this.canvas?.id==='view' && source instanceof HTMLImageElement) {
     const url=source.currentSrc || source.src, seq=new URL(url,location.href).searchParams.get('seq');
     window.__fpsDraws.push({now_ms:performance.now(),frame_id:seq, image_url:url,stamp:document.getElementById('stamp')?.textContent,
      natural_width:source.naturalWidth,natural_height:source.naturalHeight});
    }return r;
   };
  });
  page.on('pageerror',e=>errors.push(String(e)));
  page.on('requestfailed',r=>errors.push({request:r.url(),failure:r.failure()}));
  page.on('response',response=>{
   const url=response.url(),kind=url.includes('/api/state')?'state':url.includes('frame.png')?'image':null;
   if(!kind)return;
   const promise=(async()=>{
    const request=response.request(),data={url,kind,status:response.status(),seen_node_ms:Date.now()};
    try {
      const body=await response.body(),timing=request.timing();data.bytes=body.length;data.total_ms=timing.responseEnd>=0?timing.responseEnd:Date.now()-data.seen_node_ms;
      if(kind==='image')data.sha256=crypto.createHash('sha256').update(body).digest('hex');
      if(kind==='state') {const s=JSON.parse(body);data.snapshot_age_ms=s.snapshot_age_ms;data.frame_id=s.tracking?.frame_id;data.timestamp_ms=s.tracking?.timestamp_ms;data.sample_ms=s.tracking?.sample_ms;data.connected=s.connected;}
    } catch(e){data.error=String(e)}
    responses.push(data);
   })();pending.add(promise);promise.finally(()=>pending.delete(promise));
  });
  await page.goto(base+'/',{waitUntil:'domcontentloaded',timeout:20000});
  const start=await page.evaluate(()=>performance.now()),wall=Date.now();
  await page.waitForTimeout(duration*1000);
  const end=await page.evaluate(()=>performance.now()), displays=(await page.evaluate(()=>window.__fpsDraws)).filter(e=>e.now_ms>=start && e.now_ms<=end);
  await Promise.allSettled([...pending]);
  const summary=summarize(name,(end-start)/1000,displays,responses,errors,Date.now()-wall);
  fs.writeFileSync(path.join(out,name+'_samples.json'),JSON.stringify({start_ms:start,end_ms:end,displays,responses,errors},null,2));
  await page.screenshot({path:path.join(out,name+'_preview.png'),fullPage:true});
  result.pages.push(summary);fs.writeFileSync(path.join(out,'measurement.json'),JSON.stringify(result,null,2));
  console.log(JSON.stringify(summary));await page.close();
 }
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
