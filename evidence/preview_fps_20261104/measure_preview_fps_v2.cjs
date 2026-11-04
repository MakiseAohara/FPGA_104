// Read-only measurement. Use --out <new directory>; never overwrite baseline/.
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {chromium}=require('C:/Users/Makise Aohara/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const outIndex=process.argv.indexOf('--out');
const out=outIndex>=0?path.resolve(process.argv[outIndex+1]):path.join(__dirname,'latest');
if(path.resolve(out)===path.resolve(__dirname,'baseline'))throw Error('Refusing to overwrite preserved baseline evidence');
fs.mkdirSync(out,{recursive:true});
function percentile(values,p){if(!values.length)return null;const a=[...values].sort((x,y)=>x-y);return a[Math.min(a.length-1,Math.floor(p*a.length))]}
function summarize(name,duration,displays,responses,errors,wall_ms){
 const ids=[],contents=[],uniqueDisplays=[];
 for(const e of displays)if(e.frame_id!==null && !ids.includes(e.frame_id)){ids.push(e.frame_id);uniqueDisplays.push(e)}
 for(const r of responses){const hash=r.pixel_sha256||r.sha256;if(['image','preview'].includes(r.kind)&&hash&&!contents.includes(hash))contents.push(hash)}
 const responseTimes=kind=>responses.filter(r=>r.kind===kind&&r.status===200).map(r=>r.total_ms).filter(v=>Number.isFinite(v)&&v>=0);
 const times=values=>({median:percentile(values,.5),p95:percentile(values,.95)});
 const intervals=uniqueDisplays.slice(1).map((e,i)=>e.now_ms-uniqueDisplays[i].now_ms);
 return{name,measurement_seconds:duration,wall_ms,draw_completions:displays.length,unique_frame_ids:ids.length,
  repeated_draws:displays.length-uniqueDisplays.length,unidentified_draws:displays.filter(e=>e.frame_id===null).length,
  repeat_fraction:displays.length?(displays.length-uniqueDisplays.length)/displays.length:null,
  unique_frames_per_window_second:ids.length/duration,
  steady_unique_fps:uniqueDisplays.length>1?(uniqueDisplays.length-1)*1000/(uniqueDisplays.at(-1).now_ms-uniqueDisplays[0].now_ms):null,
  unique_frame_ids_displayed:ids,unique_image_contents:contents.length,
  canvas_source_draws:displays.filter(e=>e.source_type==='HTMLCanvasElement').length,
  image_source_draws:displays.filter(e=>e.source_type==='HTMLImageElement').length,
  packed_requests:responses.filter(r=>r.kind==='preview').length,
  image_total_ms:times(responseTimes('image')),state_total_ms:times(responseTimes('state')),
  preview_total_ms:times(responseTimes('preview')),inter_unique_frame_ms:times(intervals),errors:JSON.parse(JSON.stringify(errors)),
  responses_failed:responses.filter(r=>(r.status!==200&&!(r.kind==='preview'&&r.status===404))||r.error).length};
}
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,args:['--no-proxy-server']});
 const result={method:'Edge canvas drawImage completion (Image or Canvas source); unique DOM snapshot IDs, not page timers',captured_at:new Date().toISOString(),pages:[]};
 try{
  for(const [name,base,duration] of [['pc','http://169.254.47.62:8090',20],['board','http://169.254.47.63',10]]){
   const page=await browser.newPage({viewport:{width:1450,height:1050}}),responses=[],errors=[],pending=new Set();
   await page.addInitScript(()=>{
    window.__fpsDraws=[];
    const original=CanvasRenderingContext2D.prototype.drawImage;
    CanvasRenderingContext2D.prototype.drawImage=function(...args){
     const result=original.apply(this,args),source=args[0];
     if(this.canvas?.id==='view'&&(source instanceof HTMLImageElement||source instanceof HTMLCanvasElement)){
      const stamp=document.getElementById('stamp')?.textContent||'',stampId=stamp.match(/快照\s+(\d+)/)?.[1];
      const domId=document.getElementById('frame-no')?.textContent?.trim();
      const url=source instanceof HTMLImageElement?(source.currentSrc||source.src):null;
      const urlId=url?new URL(url,location.href).searchParams.get('seq'):null;
      const id=stampId||(/^\d+$/.test(domId||'')?domId:null)||urlId;
      const record={now_ms:performance.now(),frame_id:id,frame_id_source:stampId?'stamp':(/^\d+$/.test(domId||'')?'frame-no':urlId?'image URL':'unknown'),
       image_url:url,stamp,source_type:source.constructor.name,natural_width:source.naturalWidth||source.width,natural_height:source.naturalHeight||source.height,geometry:args.slice(1)};
      try{
       let surface=source;
       if(source instanceof HTMLImageElement){surface=document.createElement('canvas');surface.width=source.naturalWidth;surface.height=source.naturalHeight;original.call(surface.getContext('2d'),source,0,0)}
       const data=surface.getContext('2d').getImageData(0,0,surface.width,surface.height).data;
       let hash=2166136261;
       for(let i=0;i<data.length;i++){hash^=data[i];hash=Math.imul(hash,16777619)}
       record.source_rgba_fnv1a32=(hash>>>0).toString(16).padStart(8,'0');
      }catch(e){record.hash_error=String(e)}
      window.__fpsDraws.push(record);
     }return result;
    };
   });
   page.on('pageerror',e=>errors.push(String(e)));
   page.on('requestfailed',r=>errors.push({request:r.url(),failure:r.failure()}));
   page.on('response',response=>{
    const url=response.url(),pathname=new URL(url).pathname;
    const kind=pathname==='/api/preview'?'preview':pathname==='/api/state'?'state':pathname.endsWith('frame.png')?'image':null;
    if(!kind)return;
    const promise=(async()=>{
     const request=response.request(),data={url,kind,status:response.status(),seen_node_ms:Date.now()};
     try{
      const body=await response.body(),timing=request.timing();data.bytes=body.length;data.total_ms=timing.responseEnd>=0?timing.responseEnd:Date.now()-data.seen_node_ms;
      let state;
      if(kind==='image')data.sha256=crypto.createHash('sha256').update(body).digest('hex');
      if(kind==='state'&&response.status()===200)state=JSON.parse(body);
      if(kind==='preview'&&response.status()===200){
       if(body.length<24||body.subarray(0,4).toString()!=='MMTP')throw Error('Malformed packed response');
       const n=body.readUInt32BE(8),w=body.readUInt16BE(12),h=body.readUInt16BE(14),seq=body.readUInt32BE(16),size=body.readUInt32BE(20);
       if(body.length!==24+n+size||size!==w*h)throw Error('Incomplete packed response');
       state=JSON.parse(body.subarray(24,24+n));if(state.tracking?.frame_id!==seq)throw Error('Capture ID mismatch');
       data.width=w;data.height=h;data.pixel_sha256=crypto.createHash('sha256').update(body.subarray(24+n)).digest('hex');
      }
      if(state){data.snapshot_age_ms=state.snapshot_age_ms;data.frame_id=state.tracking?.frame_id;data.timestamp_ms=state.tracking?.timestamp_ms;data.sample_ms=state.tracking?.sample_ms;data.connected=state.connected}
     }catch(e){data.error=String(e)}
     responses.push(data);
    })();pending.add(promise);promise.finally(()=>pending.delete(promise));
   });
   await page.goto(base+'/',{waitUntil:'domcontentloaded',timeout:20000});
   const start=await page.evaluate(()=>performance.now()),wall=Date.now();
   await page.waitForTimeout(duration*1000);
   const end=await page.evaluate(()=>performance.now()),displays=(await page.evaluate(()=>window.__fpsDraws)).filter(e=>e.now_ms>=start&&e.now_ms<=end);
   await Promise.allSettled([...pending]);
   const summary=summarize(name,(end-start)/1000,displays,responses,errors,Date.now()-wall);
   fs.writeFileSync(path.join(out,name+'_samples.json'),JSON.stringify({start_ms:start,end_ms:end,displays,responses,errors},null,2));
   await page.screenshot({path:path.join(out,name+'_preview.png'),fullPage:true});
   result.pages.push(summary);fs.writeFileSync(path.join(out,'measurement.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(summary));await page.close();
  }
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
