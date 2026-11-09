(function(global){
'use strict';
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
class JSONNumber { constructor(source){this.source=source;} }
const isObject=v=>v!==null&&typeof v==='object'&&!(v instanceof JSONNumber);
// Validate with the platform parser, then retain numeric lexemes for IDs beyond 2^53.
function parseJSON(source){
 JSON.parse(source);
 let at=0;
 const space=()=>{while(/\s/.test(source[at]||'')&&at<source.length)at++;};
 function string(){const start=at++;while(at<source.length){const ch=source[at++];if(ch==='\\'){at++;continue;}if(ch==='"')break;}return JSON.parse(source.slice(start,at));}
 function value(){
  space();const ch=source[at];
  if(ch==='"')return string();
  if(ch==='{'){
   const result=Object.create(null);at++;space();
   while(source[at]!=='}'){const key=string();space();at++;result[key]=value();space();if(source[at]===','){at++;space();}else break;}
   at++;return result;
  }
  if(ch==='['){const result=[];at++;space();while(source[at]!==']'){result.push(value());space();if(source[at]===','){at++;space();}else break;}at++;return result;}
  for(const [word,result] of [['true',true],['false',false],['null',null]])if(source.startsWith(word,at)){at+=word.length;return result;}
  const number=source.slice(at).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)[0];at+=number.length;return new JSONNumber(number);
 }
 return value();
}
function envelope(text){
 const trimmed=text.trim();
 try { return {value:parseJSON(trimmed),prefix:'',raw:trimmed}; } catch(_) {}
 const newline=trimmed.indexOf('\n');
 if(newline>0 && /^[\w./ :—-]+$/.test(trimmed.slice(0,newline))){
  try{return {value:parseJSON(trimmed.slice(newline+1)),prefix:trimmed.slice(0,newline),raw:trimmed.slice(newline+1).trim()};}catch(_){}
 }
 return null;
}
function highlight(source,language){
 const re=/("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b(?:true|false|null|undefined|const|let|var|function|return|if|else|for|in|of|class|import|from|export|async|await|def|print|struct|func|guard|nil|try|throw)\b)|(\b\d+(?:\.\d+)?\b)|(\/\/[^\n]*|#[^\n]*)/g;
 let out='',start=0;
 for(const m of source.matchAll(re)){out+=esc(source.slice(start,m.index));out+='<span class="'+(m[1]?'str':m[2]?'kw':m[3]?'num':'comment')+'">'+esc(m[0])+'</span>';start=m.index+m[0].length;}
 return out+esc(source.slice(start));
}
function primitive(v){if(v instanceof JSONNumber)return '<span class="num">'+esc(v.source)+'</span>';if(typeof v==='string')return '<span class="str">'+esc(JSON.stringify(v))+'</span>';if(v===null)return '<span class="null">null</span>';return '<span class="'+(typeof v==='number'?'num':'bool')+'">'+esc(JSON.stringify(v))+'</span>';}
function jsonTree(value,path='root',depth=0,compact=false,key=null,comma=''){
 const image=global.UnfoldImages?.detect(value);
 if(image)return global.UnfoldImages.render(image);
 const keyHTML=key===null?'':'<span class="key">'+esc(JSON.stringify(key))+'</span><span class="punctuation">: </span>';
 if(typeof value==='string'&&/^\s*[\[{]/.test(value)&&/"(?:data|image_url|imageUrl|b64_json|mimeType|mime_type)"\s*:/.test(value)){const nested=envelope(value);if(nested&&isObject(nested.value))return '<div>'+keyHTML+jsonTree(nested.value,path+'/content',depth+1,compact)+comma+'</div>';}
 if(typeof value==='string'&&isHTML(value))return '<div>'+keyHTML+'<div class="json-html" data-source="'+esc(value)+'"></div>'+comma+'</div>';
 if(!isObject(value))return '<div>'+keyHTML+primitive(value)+comma+'</div>';
 const entries=Array.isArray(value)?value.map((v,i)=>[null,v,String(i)]):Object.entries(value).map(([k,v])=>[k,v,k]);
 const [open,close]=Array.isArray(value)?['[',']']:['{','}'];
 if(!entries.length)return '<div>'+keyHTML+'<span class="punctuation">'+open+close+comma+'</span></div>';
 // Short scalar maps read across the pane, with every field visible.
 const inline=!Array.isArray(value)&&entries.length>1&&entries.every(([k,v])=>k.length<=40&&!isObject(v)&&(typeof v!=='string'||(v.length<=32&&!/[\r\n]/.test(v)&&!isHTML(v)))&&(!(v instanceof JSONNumber)||v.source.length<=32));
 if(inline)return '<div class="json-inline"><span class="json-inline-label">'+keyHTML+'<span class="punctuation">{</span></span>'+entries.map(([k,v],i)=>'<span class="json-pair'+(v===true?' flag-true':'')+'"><span class="key">'+esc(JSON.stringify(k))+'</span><span class="punctuation">: </span>'+primitive(v)+(i===entries.length-1?'':'<span class="punctuation">,</span>')+'</span>').join(' ')+'<span class="punctuation">}'+comma+'</span></div>';
 const label=entries.length+' '+(Array.isArray(value)?(entries.length===1?'item':'items'):(entries.length===1?'field':'fields'));
 const expanded=true;
 return '<details class="json-node" data-path="'+esc(path)+'" '+(expanded?'open':'')+'><summary>'+keyHTML+'<span class="punctuation json-collapsed">'+open+' … '+close+comma+'</span><span class="punctuation json-opened">'+open+'</span><span class="json-count">'+label+'</span></summary><div class="json-children">'+entries.map(([k,v,id],i)=>jsonTree(v,path+'/'+id,depth+1,compact,k,i===entries.length-1?'':',')).join('')+'</div><div class="json-closing punctuation">'+close+comma+'</div></details>';
}
function jsonCard(value,compact=false,original=null){const raw=(original??JSON.stringify(value,null,2)).replace(/^\s*\n/gm,'');return '<section class="json-card"><div class="card-bar"><span>JSON</span><button data-action="copy" data-copy="'+esc(raw)+'" aria-label="Copy JSON">Copy</button></div><div class="json-tree">'+jsonTree(value,'root',0,false)+'</div></section>';}
const htmlPattern=/^\s*(?:<!doctype\s+html|<(?:html|head|body|main|article|section|div|style|table|svg|form|h[1-6]|p)(?:\s|>))/i;
function isHTML(text){return htmlPattern.test(text);}
function codeCard(source,language='text'){return '<section class="code-card"><div class="card-bar"><span>'+esc(language||'text')+'</span><button data-action="copy" data-copy="'+esc(source)+'" aria-label="Copy code">Copy</button></div><pre><code>'+highlight(source,language)+'</code></pre></section>';}
const pythonCache=new Map(),pythonSources=new Map(),pythonKeys=new Map(),pythonPending=new Set();
let pythonCounter=0;
function pythonKey(source){if(!pythonKeys.has(source)){const key='python-'+(++pythonCounter);pythonKeys.set(source,key);pythonSources.set(key,source);}return pythonKeys.get(source);}
function pythonHighlight(source){return global.hljs?hljs.highlight(source,{language:'python',ignoreIllegals:true}).value:highlight(source,'python');}
function pythonStatus(result){if(!result)return 'Checking Python…';if(result.state==='clean')return 'Ruff · Lint clean';if(result.state==='issues')return 'Ruff · '+result.diagnostics.length+' lint '+(result.diagnostics.length===1?'finding':'findings');return 'Lint unavailable';}
function pythonListing(source,diagnostics=[]){
 const lines=source.replace(/\n$/,'').split('\n');
 const gutter=lines.map((_,i)=>{const issues=diagnostics.filter(d=>d.line===i+1),label=issues.map(d=>d.code+': '+d.message).join('\n');return '<div class="line-number'+(issues.length?' has-diagnostic':'')+'" title="'+esc(label)+'">'+(i+1)+'</div>';}).join('');
 return '<div class="python-listing"><div class="python-gutter" aria-hidden="true">'+gutter+'</div><pre><code class="language-python">'+pythonHighlight(source.replace(/\n$/,''))+'</code></pre></div>';
}
function pythonDiagnostics(result){
 if(!result)return '';
 if(result.state==='unavailable')return '<div class="lint-unavailable">'+esc(result.message||'Lint unavailable')+'</div>';
 if(!result.diagnostics.length)return '';
 return '<ul class="lint-diagnostics">'+result.diagnostics.map(d=>'<li><span class="lint-code">'+esc(d.code)+'</span><span class="lint-location">'+d.line+':'+d.column+'</span><span>'+esc(d.message)+'</span></li>').join('')+'</ul>';
}
function pythonCard(source,origin='Python'){
 const key=pythonKey(source),result=pythonCache.get(key),formatted=result?result.formatted:source;
 return '<section class="code-card python-card" data-python-key="'+key+'"><div class="card-bar"><span class="python-title">Python</span><span class="lint-status '+(result?result.state:'pending')+'">'+pythonStatus(result)+'</span><button data-action="copy" data-copy="'+esc(formatted)+'" aria-label="Copy Python">Copy Python</button></div><div class="python-rendered">'+pythonListing(formatted,result?result.diagnostics:[])+'</div><div class="python-diagnostics">'+pythonDiagnostics(result)+'</div><details class="python-original" data-path="'+key+'-original"><summary>Original Python</summary><pre><code>'+pythonHighlight(source)+'</code></pre></details></section>';
}
function requestPythonAnalysis(){
 for(const card of document.querySelectorAll('.python-card')){const key=card.dataset.pythonKey;if(pythonCache.has(key)||pythonPending.has(key))continue;pythonPending.add(key);native({action:'lintPython',key,source:pythonSources.get(key)});}
}
function applyPythonResult(key,result){
 pythonCache.set(key,result);pythonPending.delete(key);
 for(const card of document.querySelectorAll('.python-card[data-python-key="'+key+'"]')){
  card.querySelector('.python-rendered').innerHTML=pythonListing(result.formatted,result.diagnostics);
  card.querySelector('.python-diagnostics').innerHTML=pythonDiagnostics(result);
  const status=card.querySelector('.lint-status');status.textContent=pythonStatus(result);status.className='lint-status '+result.state;
  card.querySelector('[data-action=copy]').dataset.copy=result.formatted;
 }
}
function previewDocument(html){
 const doc=new DOMParser().parseFromString(html,'text/html');
 doc.querySelectorAll('base,meta[http-equiv],iframe,object,embed').forEach(el=>el.remove());
 const meta=doc.createElement('meta');meta.httpEquiv='Content-Security-Policy';meta.content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline' https:; img-src data: https: http:; font-src data: https:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'";
 doc.head.prepend(meta);
 const baseStyle=doc.createElement('style');baseStyle.textContent='html{color-scheme:light}body{margin:16px;font-family:system-ui,sans-serif}img,svg,video{max-width:100%}';doc.head.insertBefore(baseStyle,meta.nextSibling);
 return '<!doctype html>'+doc.documentElement.outerHTML;
}
function makePreview(source,index){
 const card=document.createElement('section');card.className='preview-card';card.dataset.source=source;
 card.innerHTML='<div class="card-bar"><span>HTML preview</span><div class="card-actions"><button data-action="copy" aria-label="Copy HTML">Copy</button><button data-action="expand" aria-label="Open HTML preview in a window">Open window ↗</button></div></div><div class="preview-resize"><iframe class="preview-frame" title="HTML preview" sandbox="" referrerpolicy="no-referrer"></iframe></div><details class="source" data-path="html-source-'+index+'"><summary>View HTML source</summary><pre><code>'+highlight(source,'html')+'</code></pre></details>';
 card.querySelector('[data-action=copy]').dataset.copy=source;
 card.querySelector('[data-action=expand]').dataset.html=source;
 card.querySelector('iframe').srcdoc=previewDocument(source);
 return card;
}
let widgetID=0;
function renderBody(record){
 const source=record.text||'',kind=record.kind;
 const image=global.UnfoldImages?.detect(source);
 if(image)return {html:global.UnfoldImages.render(image),widgets:[]};
 if(record.python&&record.python.length){return {html:record.python.map(s=>pythonCard(s.source,s.origin)).join('')+'<details class="shell-wrapper" data-path="shell-wrapper"><summary>Original shell command</summary>'+codeCard(source,'shell')+'</details>',widgets:[]};}
 if(record.language&&/^(python|py)$/.test(record.language))return {html:pythonCard(source),widgets:[]};
 const parsed=envelope(source);
 const parsedImage=parsed&&global.UnfoldImages?.detect(parsed.value);
 if(parsedImage)return {html:global.UnfoldImages.render(parsedImage),widgets:[]};
 if(parsed && isObject(parsed.value)){
  const compact=kind==='Session'||/metadata/i.test(parsed.prefix);
  return {html:(parsed.prefix?'<div class="event-name">'+esc(parsed.prefix)+'</div>':'')+jsonCard(parsed.value,false,parsed.raw),widgets:[],metadata:compact};
 }
 if(record.language && /^(json|jsonc)$/i.test(record.language)&&parsed)return {html:jsonCard(parsed.value,false,parsed.raw),widgets:[]};
 if((record.language&&/^(html?|svg)$/i.test(record.language))||isHTML(source))return {html:'<div data-widget="0"></div>',widgets:[{id:0,source}],metadata:false};
 if(['Command','Output','File change','Code'].includes(kind))return {html:codeCard(source,record.language||({'Command':'shell','Output':'output','File change':'diff'}[kind]||'text')),widgets:[]};
 const widgets=[];
 const renderer={image(token){const image=global.UnfoldImages?.detect({type:'image',url:token.href,alt:token.text});return image?global.UnfoldImages.render(image):'<span>'+esc(token.text||'Image unavailable')+'</span>';},code(token){const image=global.UnfoldImages?.detect(token.text);if(image)return global.UnfoldImages.render(image);const lang=(token.lang||'text').split(/\s+/)[0];if(/^(python|py)$/i.test(lang))return pythonCard(token.text);if(/^(html?|svg)$/i.test(lang)){const id=++widgetID;widgets.push({id,source:token.text});return '<div data-widget="'+id+'"></div>';}if(lang==='json'){try{return jsonCard(parseJSON(token.text),false,token.text);}catch(_){}}return codeCard(token.text,lang);},html(token){if(token.block&&isHTML(token.text)){const id=++widgetID;widgets.push({id,source:token.text});return '<div data-widget="'+id+'"></div>';}return token.text;}};
 // Per-render instances keep custom renderers from accumulating in the streaming loop.
 const parser=new marked.Marked({gfm:true,breaks:false});parser.use({renderer});
 const html=DOMPurify.sanitize(parser.parse(source),{ADD_ATTR:['data-widget','data-action','data-copy','data-path','data-image-key','open','aria-label','loading','decoding'],FORBID_TAGS:['style','script','iframe','form','object','embed'],FORBID_ATTR:['style']});
 return {html,widgets,metadata:false};
}
let records=[],follow=true,size=16,updating=false;
function native(payload){if(global.webkit&&global.webkit.messageHandlers&&global.webkit.messageHandlers.unfold)global.webkit.messageHandlers.unfold.postMessage(payload);}
function article(record,index,old){
 const content=renderBody(record),el=document.createElement('article');
 const kind=record.kind||'Session';el.className='record '+({'Reasoning summary':'reasoning','You':'user','Command':'command','Error':'error','Session':'system','Tool':'tool'}[kind]||'agent')+(content.metadata?' metadata':'');el.dataset.index=index;
 const date=new Date((record.time+978307200)*1000);
 el.innerHTML='<header class="record-header"><span class="kind-dot" aria-hidden="true"></span><span class="kind">'+esc(kind==='Agent'?'Assistant':kind)+'</span><time>'+date.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})+'</time></header><div class="body">'+content.html+'</div>';
 const stateKey=(d,root)=>{const cards=[...root.querySelectorAll('.json-card')];return cards.indexOf(d.closest('.json-card'))+':'+d.dataset.path;};
 const oldStates=new Map(old?[...old.querySelectorAll('details[data-path]')].map(d=>[stateKey(d,old),d.open]):[]);
 for(const w of content.widgets){
  const target=el.querySelector('[data-widget="'+w.id+'"]');if(!target)continue;
  const retained=old&&[...old.querySelectorAll('.preview-card')].find(c=>c.dataset.source===w.source);
  target.replaceWith(retained||makePreview(w.source,index));
 }
 for(const target of el.querySelectorAll('.json-html'))target.replaceWith(makePreview(target.dataset.source,index));
 for(const d of el.querySelectorAll('details[data-path]')){const key=stateKey(d,el);if(oldStates.has(key))d.open=oldStates.get(key);}
 for(const link of el.querySelectorAll('a[href]')){link.rel='noreferrer noopener';link.title=link.href;}
 return el;
}
function apply(payload){
 const feed=document.getElementById('feed');updating=true;follow=payload.follow??follow;
 const top=global.scrollY;const start=payload.start||0;
 if(payload.replace){records=[];feed.replaceChildren();}
 for(let i=0;i<payload.records.length;i++){
  const index=start+i,r=payload.records[i],old=feed.querySelector('article[data-index="'+index+'"]');records[index]=r;
  const el=article(r,index,old);if(old)old.replaceWith(el);else feed.append(el);
 }
 for(const el of feed.querySelectorAll('article'))if(+el.dataset.index>=records.length)el.remove();
 if(follow && !global.getSelection().toString())global.scrollTo(0,document.body.scrollHeight);else global.scrollTo(0,top);
 updating=false;requestPythonAnalysis();global.UnfoldImages?.hydrate();
}
function setFollow(value){follow=value;if(follow)global.scrollTo(0,document.body.scrollHeight);}
function setSize(value){size=Math.min(28,Math.max(8,value));document.documentElement.style.setProperty('--body',size+'px');document.documentElement.style.setProperty('--code',Math.max(8,size-2)+'px');}
function standalone(source){document.body.innerHTML='';const preview=makePreview(source,0);preview.querySelector('.card-bar').remove();preview.querySelector('.source').remove();preview.style.cssText='margin:0;border:0;border-radius:0;height:100vh';preview.querySelector('.preview-resize').style.cssText='height:100vh;max-height:none;resize:none';document.body.append(preview);}
if(typeof document!=='undefined'){
 document.addEventListener('click',e=>{const button=e.target.closest('button[data-action]');if(!button)return;
  if(button.dataset.action==='copy'){native({action:'copy',text:button.dataset.copy});const old=button.textContent;button.textContent='Copied';setTimeout(()=>button.textContent=old,1200);}
  if(button.dataset.action==='expand')native({action:'preview',html:button.dataset.html});
 });
 global.addEventListener('wheel',e=>{if(e.deltaY<0 && follow){follow=false;native({action:'follow',value:false});}},{passive:true});
 global.addEventListener('keydown',e=>{if(['PageUp','Home','ArrowUp'].includes(e.key)&&follow){follow=false;native({action:'follow',value:false});}});
 new ResizeObserver(()=>{if(follow&&!updating&&!global.getSelection().toString())global.scrollTo(0,document.body.scrollHeight);}).observe(document.body);
}
global.UnfoldRenderer={apply,setFollow,setSize,standalone,applyPythonResult,envelope,parseJSON,jsonTree,isHTML,previewDocument,renderBody};
})(globalThis);
