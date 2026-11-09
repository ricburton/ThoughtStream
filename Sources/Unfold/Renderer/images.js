(function(global){
'use strict';
const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const extension=/\.(?:png|jpe?g|gif|webp|svg|avif|heic|heif|tiff?|bmp|ico|icns|jp2|jxl)(?:[?#].*)?$/i;
const sources=new Map(),results=new Map(),pending=new Set(),keys=new Map();
let next=0;
function signature(data){
 const head=data.slice(0,80).replace(/\s/g,'');
 if(head.startsWith('/9j/'))return 'image/jpeg';
 if(head.startsWith('iVBORw0KGgo'))return 'image/png';
 if(head.startsWith('R0lGOD'))return 'image/gif';
 if(head.startsWith('UklGR'))return 'image/webp';
 if(head.startsWith('SUkq')||head.startsWith('TU0AK'))return 'image/tiff';
 if(head.startsWith('Qk'))return 'image/bmp';
 if(head.startsWith('AAABAA')||head.startsWith('AAACAA'))return 'image/x-icon';
 try {const bytes=atob(head);if(bytes.slice(4,8)==='ftyp')return /avif|avis/.test(bytes)?'image/avif':'image/heic';if(/<svg[\s>]/i.test(bytes))return 'image/svg+xml';} catch(_){}
 return null;
}
function location(source,typed=false){
 if(typeof source!=='string')return null;
 const value=source.trim();
 if(/^data:image\/[\w.+-]+[;,]/i.test(value))return {src:value};
 const mime=signature(value);
 if(mime&&value.length>=24&&/^[\w+/=\s-]+$/.test(value))return {src:'data:'+mime+';base64,'+value.replace(/\s/g,'')};
 if(!typed&&!extension.test(value))return null;
 if(/^https?:\/\//i.test(value))return {src:value};
 if(/^(?:file:\/\/|\/|~\/|\.\.?\/)/.test(value)||(!/^[a-z]+:/i.test(value)&&extension.test(value)))return {path:value};
 return null;
}
function detect(value){
 if(typeof value==='string')return location(value);
 if(!value||typeof value!=='object'||Array.isArray(value))return null;
 const mime=value.mimeType||value.mime_type||value.media_type;
 const typed=/^(?:image|input_image|output_image|image_url|local_image)$/i.test(value.type||'')||/^image\//.test(mime||'');
 const data=value.data||value.b64_json||value.base64||value.blob;
 if(typeof data==='string'&&(typed||/^image\//.test(mime||'')||signature(data))){
  const result=location(data,true)||(mime&&/^image\/[\w.+-]+$/.test(mime)?{src:'data:'+mime+';base64,'+data.replace(/\s/g,'')}:null);
  if(result)return {...result,alt:value.alt||value.name||'Image'};
 }
 if(typed&&value.source){const result=detect(value.source)||location(typeof value.source==='object'?value.source.url:value.source,true);if(result)return result;}
 const candidate=value.image_url||value.imageUrl||value.image_path||value.imagePath||((typed||Object.keys(value).length<=5)&&(value.url||value.path||value.file_path||value.uri));
 const result=location(typeof candidate==='object'?candidate?.url:candidate,typed||!!value.image_url||!!value.imageUrl);
 return result?{...result,alt:value.alt||value.name||'Image'}:null;
}
function render(image){
 const identity=image.path||image.src;
 let key=keys.get(identity);
 if(!key){key='image-'+(++next);keys.set(identity,key);sources.set(key,image);}
 const result=results.get(key),src=result?.src||image.src,problem=result?.error;
 return '<figure class="image-card" data-image-key="'+key+'"><div class="card-bar"><span>'+escape(image.alt||'Image')+'</span><span class="image-dimensions"></span><button data-action="open-image" aria-label="Open image at full size" '+(!src?'disabled':'')+'>Open image ↗</button></div>'+
  (src?'<img class="feed-image" src="'+escape(src)+'" alt="'+escape(image.alt||'Image')+'" loading="lazy" decoding="async">':'')+
  '<div class="image-message" '+(src&&!problem?'hidden':'')+'>'+escape(problem||(image.path?'Loading image…':'Decoding image…'))+'</div></figure>';
}
function native(payload){global.webkit?.messageHandlers?.unfold?.postMessage(payload);}
function request(key){
 if(pending.has(key)||results.has(key))return;
 const image=sources.get(key);if(!image)return;
 pending.add(key);native({action:'loadImage',key,...image});
}
function hydrate(){
 for(const card of document.querySelectorAll('.image-card')){
  const key=card.dataset.imageKey,img=card.querySelector('img');
  if(!img)request(key);
  else if(img.complete&&img.naturalWidth)dimensions(img);
 }
}
function dimensions(img){
 const card=img.closest('.image-card');if(!card)return;
 card.querySelector('.image-dimensions').textContent=img.naturalWidth+' × '+img.naturalHeight;
 card.querySelector('.image-message').hidden=true;
}
function apply(key,result){
 results.set(key,result);pending.delete(key);
 for(const card of document.querySelectorAll('.image-card')){
  if(card.dataset.imageKey!==key)continue;
  const shell=document.createElement('div');shell.innerHTML=render(sources.get(key));card.replaceWith(shell.firstElementChild);
 }
 hydrate();
}
document.addEventListener('load',e=>{if(e.target.matches?.('.feed-image'))dimensions(e.target);},true);
document.addEventListener('error',e=>{
 const img=e.target;if(!img.matches?.('.feed-image'))return;
 const card=img.closest('.image-card'),key=card.dataset.imageKey,image=sources.get(key);
 if(!results.has(key)&&image?.src?.startsWith('data:'))request(key);
 else {card.querySelector('.image-message').hidden=false;card.querySelector('.image-message').textContent='This image could not be loaded.';}
},true);
document.addEventListener('click',e=>{
 const button=e.target.closest('[data-action="open-image"]');if(!button)return;
 const src=button.closest('.image-card').querySelector('img')?.src;if(!src)return;
 native({action:'preview',title:'Image',html:'<img src="'+escape(src)+'" style="display:block;margin:auto;max-width:100%;height:auto" alt="Image">'});
});
global.UnfoldImages={detect,render,hydrate,apply};
})(globalThis);
