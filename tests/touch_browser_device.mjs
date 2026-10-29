#!/usr/bin/env node
// Opt-in end-to-end test: idle unlocked Pad, active desktop and touch enabled.
// Uses a fresh Chrome profile and a local test page; never opens user content.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const [out, jar, transport = "USB"] = process.argv.slice(2);
assert(out && jar, 'output-directory fixture-jar');
fs.mkdirSync(out, {recursive:true});
const adb=process.env.ADB || path.join(os.homedir(),'Library/Android/sdk/platform-tools/adb');
const devices=execFileSync(adb,['devices','-l'],{encoding:'utf8'}).split('\n').filter(l=>l.includes(' device ')&&l.includes('usb:'));
assert.equal(devices.length,1,'one authorized USB Pad required');
const prefix=['-s',devices[0].trim().split(/\s+/)[0]];
const adbRun=(args)=>execFileSync(adb,[...prefix,...args],{encoding:'utf8',timeout:12000});
const profile=fs.mkdtempSync(path.join(os.tmpdir(),'nextend-touch-browser-'));
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const display=JSON.parse(execFileSync('/usr/bin/swift',['-e',`import CoreGraphics; import Foundation
var ids=[CGDirectDisplayID](repeating:0,count:16);var n:UInt32=0;CGGetActiveDisplayList(16,&ids,&n)
let screens=ids.prefix(Int(n)).filter{$0 != CGMainDisplayID()}.map{ id -> [String:Any] in let b=CGDisplayBounds(id);return ["x":b.minX,"y":b.minY,"width":b.width,"height":b.height]}
print(String(data:try! JSONSerialization.data(withJSONObject:screens),encoding:.utf8)!)`],{encoding:'utf8'}));
assert.equal(display.length,1,'requires just the Mac and Nextend display');
const bounds=display[0];
assert.equal(bounds.width,1600);assert.equal(bounds.height,1068);
const page=path.join(profile,'gesture.html');
fs.writeFileSync(page,'<!doctype html><meta charset="utf-8"><title>Nextend 手势验证</title><style>body{font:24px system-ui;background:#122624;color:#d6ffee;padding:40px}section{height:160px;border-bottom:1px solid #46786d}h1{position:sticky;top:0;background:#122624}</style><h1>Nextend 双指手势验证</h1>'+Array.from({length:80},(_,i)=>`<section>滚动与缩放测试 ${i+1}</section>`).join(''));
const log=fs.openSync(path.join(out,'browser.log'),'w');
let browser,ws;let sequence=0;const pending=new Map();
const report={passed:false,transport,cases:{}};
function request(method,params={},sessionId){return new Promise((resolve,reject)=>{
 const id=++sequence;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP timeout '+method));},5000);
 pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
});}
try{
 adbRun(['push',jar,'/data/local/tmp/nextend-touch-input.jar']);
 browser=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',[
  '--user-data-dir='+profile,'--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',
  '--no-first-run','--no-default-browser-check','--disable-sync','--new-window',pathToFileURL(page).href],{stdio:['ignore',log,log]});
 const active=path.join(profile,'DevToolsActivePort');
 for(let i=0;!fs.existsSync(active);i++){assert(i<100,'Chrome debugger did not start');await sleep(100);}
 const [port,endpoint]=fs.readFileSync(active,'utf8').trim().split('\n');
 ws=new WebSocket('ws://127.0.0.1:'+port+endpoint);
 await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
 ws.addEventListener('message',event=>{const r=JSON.parse(event.data);const p=pending.get(r.id);if(!p)return;clearTimeout(p.timer);pending.delete(r.id);r.error?p.reject(new Error(JSON.stringify(r.error))):p.resolve(r.result);});
 let target;
 for(let i=0;i<50;i++){const r=await request('Target.getTargets');target=r.targetInfos.find(t=>t.type==='page'&&t.url.includes('gesture.html'));if(target)break;await sleep(100);}
 assert(target,'local test target missing');
 const {sessionId}=await request('Target.attachToTarget',{targetId:target.targetId,flatten:true});
 const {windowId}=await request('Browser.getWindowForTarget',{targetId:target.targetId});
 await request('Browser.setWindowBounds',{windowId,bounds:{left:bounds.x+25,top:bounds.y+5,width:bounds.width-50,height:bounds.height-10,windowState:'normal'}});
 const evaluate=async expression=>(await request('Runtime.evaluate',{expression,returnByValue:true},sessionId)).result.value;
 const metrics=()=>evaluate('({dpr:devicePixelRatio,width:innerWidth,scrollY,screenX,screenY})');
 await sleep(500);await evaluate('window.scrollTo(0,2000)');await sleep(200);
 const before=await metrics();assert(before.screenX<0,'test window is not on the Pad display');
 const inject=pattern=>adbRun(['shell','CLASSPATH=/data/local/tmp/nextend-touch-input.jar','app_process','/','NextendTouchInput',pattern,'3200','2136']);
 inject('scroll');await sleep(400);const afterScroll=await metrics();
 assert(Math.abs(afterScroll.scrollY-before.scrollY)>20,'two-finger scroll did not change page offset');
 const cursor=JSON.parse(execFileSync('/usr/bin/swift',['-e',`import CoreGraphics; import Foundation; let p=CGEvent(source:nil)!.location; print(String(data:try! JSONSerialization.data(withJSONObject:["x":p.x,"y":p.y]),encoding:.utf8)!)`],{encoding:'utf8'}));
 assert(Math.abs(cursor.x-(bounds.x+.5*(bounds.width-1)))<3 && Math.abs(cursor.y-(bounds.y+.4*(bounds.height-1)))<3,'pointer followed fingers during scroll');
 report.cases.scroll={passed:true,offsetChanged:Math.abs(afterScroll.scrollY-before.scrollY),pointerAnchored:true};
 // Put our Nextend app on the main screen in front; pinch must still target Chrome on Pad.
 execFileSync('/usr/bin/swift',['-e','import AppKit; _=NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier=="dev.padbridge.mac"})?.activate(options:[]);RunLoop.current.run(until:Date().addingTimeInterval(0.2))']);
 inject('pinch-in');await sleep(600);const enlarged=await metrics();
 assert(enlarged.dpr>afterScroll.dpr && enlarged.width<afterScroll.width,'pinch did not enlarge the target browser');
 report.cases.pinchIn={passed:true,beforeDpr:afterScroll.dpr,afterDpr:enlarged.dpr};
 inject('pinch-out');await sleep(600);const reduced=await metrics();
 assert(reduced.dpr<enlarged.dpr && reduced.width>enlarged.width,'pinch did not reduce the target browser');
 report.cases.pinchOut={passed:true,beforeDpr:enlarged.dpr,afterDpr:reduced.dpr};
 report.passed=true;
 console.log(JSON.stringify(report,null,2));
}finally{
 fs.writeFileSync(path.join(out,'result.json'),JSON.stringify(report,null,2)+'\n');
 if(ws?.readyState===1){try{await request('Browser.close');}catch{}ws.close();}
 if(browser){for(let i=0;i<30&&browser.exitCode===null;i++)await sleep(100);if(browser.exitCode===null)browser.kill('SIGTERM');}
 for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error('test closed'));}
 try{adbRun(['shell','rm','/data/local/tmp/nextend-touch-input.jar']);}catch{}
 fs.closeSync(log);fs.rmSync(profile,{recursive:true,force:true});
}
