const fs=require('fs'),path=require('path'),assert=require('assert');
const {chromium}=require('C:/Users/Makise Aohara/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
(async()=>{
 const browser=await chromium.launch({executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true,args:['--no-proxy-server']});
 const result={passed:false,manual_person_test:false,pages:[]};
 for(const [name,url] of [['pc','http://169.254.47.62:8090/'],['board','http://169.254.47.63/']]){
  const page=await browser.newPage({viewport:{width:1450,height:1050}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));await page.goto(url,{waitUntil:'domcontentloaded',timeout:25000});
  await page.waitForFunction(()=>document.getElementById('source').textContent==='板端遥测'&&/^\d+$/.test(document.getElementById('observed').textContent)&&document.getElementById('empty').style.display==='none',{},{timeout:30000});
  assert.deepStrictEqual(await page.evaluate(()=>MMT_UI.viewRect()),{x:0,y:0,w:960,h:540});
  assert(await page.locator('#unaligned').isHidden());assert(await page.locator('#replay').isHidden());assert.deepStrictEqual(errors,[]);
  await page.screenshot({path:path.join(__dirname,name+'_live_dashboard.png'),fullPage:true});
  result.pages.push({name,url,people_count:await page.locator('#observed').innerText(),aligned:true,aspect:'16:9',no_js_errors:true});await page.close();
 }
 result.passed=true;fs.writeFileSync(path.join(__dirname,'ui_live_selftest.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
