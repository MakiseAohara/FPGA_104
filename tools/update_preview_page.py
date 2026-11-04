"""Apply the one-time preview protocol upgrade to the preserved shared page."""
from pathlib import Path
p=Path(__file__).with_name('page.html')
s=p.read_text(encoding='utf8')
if 'function decodePreview(buffer)' in s:
    print('Shared preview page already upgraded')
    raise SystemExit(0)
s=s.replace('<span class="dim" id="stamp">--</span>', '<span class="badge" id="video-fps">画面 FPS 测量中</span><span class="dim" id="stamp">--</span>')
start=s.index('async function present(st)')
end=s.index('async function control(data)',start)
replacement=r'''let packedMode=null,graySurface=null,fpsStart=performance.now(),lastCaptureKey='',captureTimes=[];
function noteCapture(k){const now=performance.now(),key=(k?.source||'legacy')+':'+(k?.frame_id??'--')+':'+(k?.timestamp_ms??'--');if(key!==lastCaptureKey){captureTimes.push(now);lastCaptureKey=key}captureTimes=captureTimes.filter(t=>now-t<5000);const elapsed=Math.min(5000,now-fpsStart);$('video-fps').textContent=elapsed>=1000?'画面 '+(captureTimes.length*1000/elapsed).toFixed(1)+' FPS':'画面 FPS 测量中'}
function decodePreview(buffer){const bytes=new Uint8Array(buffer),v=new DataView(buffer);if(bytes.length<24||String.fromCharCode(...bytes.subarray(0,4))!=='MMTP'||v.getUint8(4)!==1||v.getUint8(5)!==1||v.getUint16(6)!==24)throw Error('预览格式无效');const n=v.getUint32(8),w=v.getUint16(12),h=v.getUint16(14),seq=v.getUint32(16),size=v.getUint32(20);if(w<1||h<1||w>512||h>512||n<2||n>12288||size!==w*h||bytes.length!==24+n+size)throw Error('预览数据不完整');const state=JSON.parse(new TextDecoder().decode(bytes.subarray(24,24+n))),k=state.tracking;if(!k||k.frame_id!==seq||k.width!==w||k.height!==h)throw Error('画面与轨迹快照不匹配');return{state,pixels:bytes.subarray(24+n),width:w,height:h}}
function presentPixels(frame){const st=frame.state,k=st.tracking;generation++;if(!graySurface){graySurface=document.createElement('canvas')}graySurface.width=frame.width;graySurface.height=frame.height;const g=graySurface.getContext('2d'),rgba=g.createImageData(frame.width,frame.height);for(let i=0;i<frame.pixels.length;i++){const at=i*4,value=frame.pixels[i];rgba.data[at]=rgba.data[at+1]=rgba.data[at+2]=value;rgba.data[at+3]=255}g.putImageData(rgba,0,0);image=graySurface;show(st);noteCapture(k);$('empty').style.display='none'}
async function present(st){const key=++generation,k=st.tracking,url=typeof k?.frame_url==='string'&&k.frame_url.startsWith('/')?k.frame_url:('/frame.png?t='+Date.now());return new Promise(resolve=>{const im=new Image(),timer=setTimeout(()=>im.onerror(),10000);im.onload=()=>{clearTimeout(timer);if(key===generation){image=im;show(st);noteCapture(k);$('empty').style.display='none'}resolve()};im.onerror=()=>{clearTimeout(timer);im.onload=null;im.onerror=null;if(key===generation){image=null;show(st);$('empty').style.display='grid';$('empty').textContent='本快照无可用画面；仍显示接口提供的轨迹'}resolve()};im.src=url;})}
async function tick(){if(polling)return;polling=true;const started=performance.now();try{let frame=null;if(packedMode!==false){const r=await fetch('/api/preview',{cache:'no-store',signal:AbortSignal.timeout(5000)});if(r.status===404||(r.ok&&!String(r.headers.get('Content-Type')).includes('application/x-mmt-preview'))){packedMode=false}else{if(!r.ok)throw Error('HTTP '+r.status);frame=decodePreview(await r.arrayBuffer());packedMode=true}}if(frame){latest=frame.state;presentPixels(frame)}else{const r=await fetch('/api/state',{cache:'no-store',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('HTTP '+r.status);latest=await r.json();await present(latest)}}catch(e){$('connection').textContent='断连';$('warning').className='notice stale';$('warning').textContent='接口暂不可用，画面和轨迹已停留在最后一次有效快照。';$('message').textContent=String(e);$('video-fps').textContent='画面已暂停'}finally{polling=false;const target=latest.replay?.enabled?250:200;setTimeout(tick,Math.max(20,target-(performance.now()-started)))}}
'''
s=s[:start]+replacement+s[end:]
s=s.replace('window.MMT_UI={fitRect,speed,sourceText,show,viewRect:()=>rect}', 'window.MMT_UI={fitRect,speed,sourceText,show,decodePreview,viewRect:()=>rect}')
# Canvas-backed raw previews have width/height rather than naturalWidth.
s=s.replace('k?.aspect_width||image.naturalWidth','k?.aspect_width||image.naturalWidth||image.width')
s=s.replace('k?.aspect_height||image.naturalHeight','k?.aspect_height||image.naturalHeight||image.height')
p.write_text(s,encoding='utf8',newline='\n')
print('Shared preview page',len(p.read_bytes()),'bytes')
