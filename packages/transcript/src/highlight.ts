import hljs from 'highlight.js/lib/core';
import typescript from 'highlight.js/lib/languages/typescript';
import javascript from 'highlight.js/lib/languages/javascript';
import python from 'highlight.js/lib/languages/python';
import swift from 'highlight.js/lib/languages/swift';
import json from 'highlight.js/lib/languages/json';
import bash from 'highlight.js/lib/languages/bash';

for(const [name,definition] of Object.entries({typescript,javascript,python,swift,json,bash}))hljs.registerLanguage(name,definition);
const aliases:Record<string,string>={ts:'typescript',js:'javascript',py:'python',sh:'bash',shell:'bash'};
const cache=new Map<string,string>();let bytes=0;
export function highlightCode(text:string,language:string):string|null {
  const name=aliases[language]??language;
  if(text.length>16384 || !hljs.getLanguage(name))return null;
  const key=`${name}\0${text}`,old=cache.get(key);
  if(old!==undefined){cache.delete(key);cache.set(key,old);return old;}
  // The highlighter escapes input and emits only its own span markup. No model
  // HTML is enabled, no language auto-detection, and no network resources load.
  const html=hljs.highlight(text,{language:name,ignoreIllegals:true}).value;
  const cost=2*(key.length+html.length);if(cost>2*1024*1024)return null;
  while(cache.size>=128 || bytes+cost>2*1024*1024){const first=cache.keys().next().value!;bytes-=2*(first.length+cache.get(first)!.length);cache.delete(first);}
  cache.set(key,html);bytes+=cost;return html;
}
