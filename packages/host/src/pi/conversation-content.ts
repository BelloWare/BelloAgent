import { createHash } from 'node:crypto';
import type { SessionEntry } from '@earendil-works/pi-coding-agent';
import { textPage } from './text-page.ts';

export type ContentEntry = Extract<SessionEntry, {type:'message'|'compaction'}>;
export function contentText(entry: ContentEntry): string {
  if(entry.type==='compaction') return `## Compaction\n\n${entry.summary}\n\n`;
  const message=entry.message, content='content' in message ? message.content : '';
  const body=typeof content==='string'?content:Array.isArray(content)?content.map(block=>{
    if(block.type==='text')return block.text;
    if(block.type==='thinking')return `\n[Exposed reasoning]\n${block.thinking}\n`;
    if(block.type==='toolCall')return `\n[Tool ${block.name}]\n${JSON.stringify(block.arguments)}\n`;
    if(block.type==='image')return '\n[Image attachment omitted]\n';
    return '';
  }).join(''):'';
  return `## ${message.role}\n\n${body}\n\n`;
}
export function contentRevision(entries: ContentEntry[]): string {
  // Completed Pi entries are immutable. IDs identify the current visible branch;
  // active, unpersisted partials cannot change a paged copy halfway through.
  return createHash('sha256').update(entries.map(e=>e.id).join('\n')).digest('hex');
}
export function searchContent(entries: ContentEntry[], query: string, start: number) {
  if(query.length>256 || !Number.isSafeInteger(start) || start<0)throw new Error('Invalid history search');
  const needle=query.toLocaleLowerCase(), hits=[];let index=Math.min(start,entries.length);
  for(;index<entries.length && hits.length<100;index++) {
    const entry=entries[index]!,text=contentText(entry), at=needle?text.toLocaleLowerCase().indexOf(needle):0;
    if(at>=0)hits.push({id:entry.id,position:index+1,preview:text.slice(Math.max(0,at-60),at+180)});
  }
  return {hits,total:entries.length,next:index<entries.length?index:null,revision:contentRevision(entries)};
}
export function copyContentPage(entries: ContentEntry[], first:number,last:number,index:number,offset:number,revision:string) {
  if(revision!==contentRevision(entries))throw new Error('History changed. Refresh the range before copying');
  if(![first,last,index,offset].every(Number.isSafeInteger)||first<1||last<first||last>entries.length||index<first||index>last||offset<0)throw new Error('Invalid history range');
  const page=textPage(contentText(entries[index-1]!),offset);
  return {text:page.text,next:page.next===null?(index<last?{index:index+1,offset:0}:null):{index,offset:page.next}};
}
