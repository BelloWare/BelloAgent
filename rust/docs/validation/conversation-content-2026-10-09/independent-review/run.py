from pathlib import Path
import subprocess,hashlib,json
p=Path('/tmp/conversation-independent-review-r2'); source=(p/'conversation_content.rs').read_text();deps='/workspace/shared/build-recovery/target/debug/deps';rustc='/workspace/shared/build-recovery/toolchain/bin/rustc'
cmd=[rustc,'--edition=2024','--test',str(p/'main.rs'),'-L','dependency='+deps,'--extern','unicode_normalization='+deps+'/libunicode_normalization-bf55ebe226ba8d4a.rlib','--extern','unicode_segmentation='+deps+'/libunicode_segmentation-b0c40f093bb3669b.rlib','-o',str(p/'tests')]
mutants=[('baseline',source,None),('overlapping_count',source.replace('matched = 0;\n        }\n    }\n    search_check_cancel(cancel)?;\n    Ok(count)', 'matched = prefix[matched - 1];\n        }\n    }\n    search_check_cancel(cancel)?;\n    Ok(count)'),'occurrence_counts_nonoverlapping'),('first_occurrence_only',source.replace('count += 1;', 'count += 1; return Ok(count);'),'occurrence_counts_nonoverlapping'),('empty_count_one',source.replace('if query.is_empty() {\n        return Ok(0);','if query.is_empty() {\n        return Ok(1);'),'occurrence_counts_nonoverlapping'),('leak_reasoning',source.replace('row.text','row.reasoning'),'hidden_never_searched'),('weak_text_fence',source.replace('(&row.id, &row.text)','(&row.id, row.text.len())'),'equal_length_replacement'),('exclusive_copy_limit',source.replace('row.text.len() > COPY_LIMIT - output.len()','row.text.len() >= COPY_LIMIT - output.len()'),'exact_limit'),('include_stream',source.replace('!(session.active_reply.as_deref() == Some(row.id.as_str()) && row.state == "streaming")','{ let _ = (session, row); true }'),'active_stream_exclusion'),('ignore_search_cancel',source.replace('if cancel.load(Ordering::Acquire) {\n        Err("Conversation search was cancelled.".into())','if false {\n        Err("Conversation search was cancelled.".into())'),'cancellation_never_success')]
results=[]
try:
 for name,code,test in mutants:
  (p/'conversation_content.rs').write_text(code)
  r=subprocess.run(cmd,capture_output=True,text=True);(p/(name+'-compile.log')).write_text(r.stdout+r.stderr)
  if r.returncode: raise RuntimeError(name+' compilation failed')
  r=subprocess.run([str(p/'tests')]+([test] if test else []),capture_output=True,text=True);(p/(name+'.log')).write_text(r.stdout+r.stderr)
  results.append({'name':name,'exit':r.returncode,'expected_pass':test is None});print(name,r.returncode)
finally: (p/'conversation_content.rs').write_text(source)
(p/'results.json').write_text(json.dumps({'source_sha256':hashlib.sha256(source.encode()).hexdigest(),'results':results},indent=2))
assert all((r['exit']==0)==r['expected_pass'] for r in results)
