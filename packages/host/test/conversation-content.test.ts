import test from 'node:test';
import assert from 'node:assert/strict';
import { copyContentPage, contentText, searchContent, type ContentEntry } from '../src/pi/conversation-content.ts';

test('full retained history search crosses display pages, copies Unicode ranges and rejects stale branches',()=>{
  const entries=Array.from({length:1000},(_,n)=>({type:'message',id:`m${n}`,parentId:n?`m${n-1}`:null,timestamp:'2026-01-01T00:00:00Z',message:{role:'user',content:[{type:'text',text:n===10?'a'.repeat(16383)+'🌍 unique older needle':'ordinary'}],timestamp:0}})) as ContentEntry[];
  const found=searchContent(entries,'OLDER NEEDLE',0);
  assert.equal(found.total,1000);assert.equal(found.hits[0]?.position,11);assert.equal(found.hits.length,1);assert.equal(found.next,null);
  const first=searchContent(entries,'',0),next=searchContent(entries,'',first.next!);
  assert.equal(first.hits.length,100);assert.equal(next.hits[0]?.position,101);
  let cursor:{index:number;offset:number}|null={index:11,offset:0},copied='';
  while(cursor){const page=copyContentPage(entries,11,12,cursor.index,cursor.offset,found.revision);assert.ok(Buffer.byteLength(JSON.stringify(page))<100000);copied+=page.text;cursor=page.next;}
  assert.equal(copied,contentText(entries[10]!)+contentText(entries[11]!));assert.ok(copied.includes('🌍'));assert.ok(!copied.includes('�'));
  assert.throws(()=>copyContentPage(entries.slice(1),11,12,11,0,found.revision),/History changed/);
  assert.throws(()=>copyContentPage(entries,0,12,0,0,found.revision),/range/);
  assert.throws(()=>searchContent(entries,'x'.repeat(257),0),/search/);
});

test('conversation copy includes readable tool/reasoning/compaction text but omits opaque signatures and images',()=>{
  const entry={type:'message',id:'assistant',message:{role:'assistant',content:[{type:'thinking',thinking:'Visible reasoning',thinkingSignature:'private-signature'},{type:'text',text:'Visible answer',textSignature:'encrypted-state'},{type:'toolCall',name:'read',arguments:{path:'example.txt'}},{type:'image',data:'private-image-bytes',mimeType:'image/png'}]}} as ContentEntry;
  const text=contentText(entry);assert.ok(text.includes('Visible reasoning'));assert.ok(text.includes('example.txt'));assert.ok(text.includes('Image attachment omitted'));
  for(const secret of ['private-signature','encrypted-state','private-image-bytes'])assert.ok(!text.includes(secret));
  assert.ok(contentText({type:'compaction',summary:'Kept summary'} as ContentEntry).includes('Kept summary'));
});
