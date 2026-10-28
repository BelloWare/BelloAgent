#!/usr/bin/env python3
"""Compile fault switches only in generated sources; every selected mutant must fail assertions."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
CASES = []
UNIT = 'MailboxCutinTests/'
PERSIST = 'MailboxCutPersistenceTests/'

def active(name): return f'CutinMutation.active("{name}")'
def case(name,test,*edits): CASES.append((name,test,edits))

case('delta_boundary',UNIT+'testWholeReasoningCommentaryAndPartialAnswerOnly',('MailboxCut.swift','guard type == "response.output_item.done" else','guard type == "response.output_item.done" || '+active('delta_boundary')+' else'))
for name,kind in [('tool_boundary','function_call'),('final_boundary','final_answer'),('unknown_phase','unknown')]:
    predicate = f'item["type"].text == "{kind}"' if kind == 'function_call' else f'item["phase"].text == "{kind}"'
    case(name,UNIT+'testIneligibleItemsMissingOpaqueStateAndUnknownTypes',('MailboxCut.swift','    static func eligible(_ item: JSON) -> Bool {','    static func eligible(_ item: JSON) -> Bool {\n        if '+active(name)+' && '+predicate+' { return true }'))
# Insertion changes the single-expression function to an explicit return.
case('missing_opaque',UNIT+'testIneligibleItemsMissingOpaqueStateAndUnknownTypes',('MailboxCut.swift','case "reasoning": return item["encrypted_content"].text?.isEmpty == false','case "reasoning": return '+active('missing_opaque')+' || item["encrypted_content"].text?.isEmpty == false'))
case('partial_item',UNIT+'testOpenEarlierItemGapAndConflictingDuplicateFailClosed',('MailboxCut.swift','(0...end).allSatisfy({ completed[$0] != nil && !opened.contains($0) })','('+active('partial_item')+' || (0...end).allSatisfy({ completed[$0] != nil && !opened.contains($0) }))'))
case('terminal_race',UNIT+'testTerminalBeforeItemCompletionWins',('MailboxCut.swift','guard !terminal, !invalid,','guard !terminal || '+active('terminal_race')+', !invalid,'))
case('interleaved_call',UNIT+'testCompletedCallRetainedInProviderOrderButDoesNotCut',('MailboxCut.swift','let end = completed.keys.max() ?? index','let end = '+active('interleaved_call')+' ? index : (completed.keys.max() ?? index)'))
case('route_policy',UNIT+'testPinnedOpenAIRouteNameRuleAndEveryNegative',('MailboxCut.swift','profile.routing.policy == "pinned",','(profile.routing.policy == "pinned" || '+active('route_policy')+'),'))
case('route_identity',UNIT+'testPinnedOpenAIRouteNameRuleAndEveryNegative',('MailboxCut.swift','identity["status"].text == "reported", identity["effectiveModel"].text.map(model) == model(expected),','('+active('route_identity')+' || identity["status"].text == "reported"), ('+active('route_identity')+' || identity["effectiveModel"].text.map(model) == model(expected)),'))
case('translated_route',UNIT+'testPinnedOpenAIRouteNameRuleAndEveryNegative',('MailboxCut.swift','        let name = model(expected)','        if '+active('translated_route')+' { return true }\n        let name = model(expected)'))
case('opaque_drop',UNIT+'testCutReplayIsVerbatimIncludingOpaquePhaseAndCallArguments',('ResponsesInput.swift','{ return items }','{ return '+active('opaque_drop')+' ? Array(items.dropFirst()) : items }'))
case('phase_loss',UNIT+'testCutReplayIsVerbatimIncludingOpaquePhaseAndCallArguments',('ResponsesInput.swift','? Array(items.dropFirst()) : items }','? Array(items.dropFirst()) : ('+active('phase_loss')+' ? items.map { $0.removing(["phase"]) } : items) }'))
case('opaque_reorder',UNIT+'testCutReplayIsVerbatimIncludingOpaquePhaseAndCallArguments',('ResponsesInput.swift','? items.map { $0.removing(["phase"]) } : items) }','? items.map { $0.removing(["phase"]) } : ('+active('opaque_reorder')+' ? items.reversed().map { $0 } : items)) }'))
case('no_mail',PERSIST+'testNoMailboxAndSourceGenerationBranchHoldAndTombstoneFences',
     ('MailboxCutJournal.swift','!events.isEmpty, let journal,','(!events.isEmpty || '+active('no_mail')+'), let journal,'),
     ('MailboxCutJournal.swift','guard !events.isEmpty, let preparation','guard !events.isEmpty || '+active('no_mail')+', let preparation'))
case('queue_only','loop:reasoning',('MailboxCutJournal.swift','$0.type != nil && $0.disposition == "pending" &&','(!'+active('queue_only')+' || $0.queueOnly != true) && $0.type != nil && $0.disposition == "pending" &&'))
case('root_mail','loop:root',('MailboxCutJournal.swift','} else { owner = recipient }','} else { if '+active('root_mail')+' { return nil }; owner = recipient }'))
case('buffered_tool','loop:reasoning',('SessionRun.swift','if reply.mailboxCut != nil {','if reply.mailboxCut != nil && !'+active('buffered_tool')+' {'))
case('missing_call_result','loop:reasoning',('MailboxCutJournal.swift','for call in candidate.calls {','for call in ('+active('missing_call_result')+' ? [] : candidate.calls) {'))
case('result_id',PERSIST+'testCommittedPrefixRepairsEveryMissingRowOnceAndPreparationAloneDoesNotProject',('MailboxCutJournal.swift','try ChatMessage(id:identity($0["id"]),pi:$0["message"])','try ChatMessage(id:'+active('result_id')+' ? UUID().uuidString : identity($0["id"]),pi:$0["message"])'))
case('generation',PERSIST+'testNoMailboxAndSourceGenerationBranchHoldAndTombstoneFences',('MailboxCutJournal.swift','guard preparation["generation"].int == stopCount,','guard '+active('generation')+' || preparation["generation"].int == stopCount,'))
case('branch',PERSIST+'testNoMailboxAndSourceGenerationBranchHoldAndTombstoneFences',('MailboxCutJournal.swift','preparation["branchId"] == (context.last.map { JSON($0.id) } ?? .null),','('+active('branch')+' || preparation["branchId"] == (context.last.map { JSON($0.id) } ?? .null)),'))
case('tombstone',PERSIST+'testNoMailboxAndSourceGenerationBranchHoldAndTombstoneFences',('MailboxCutJournal.swift','!closed, !agentDeliveryHeld else { throw CancellationError() }','('+active('tombstone')+' || !closed), ('+active('tombstone')+' || !agentDeliveryHeld) else { throw CancellationError() }'))
case('recovery_prefix',PERSIST+'testCommittedPrefixRepairsEveryMissingRowOnceAndPreparationAloneDoesNotProject',('MailboxCutJournal.swift','        guard let cuts = subagents.cuts else { return }','        if '+active('recovery_prefix')+' { return }; guard let cuts = subagents.cuts else { return }'))
case('checkpoint_authority',PERSIST+'testCheckpointColdReplaySlimmingAndForkKeepExactHistoryWithoutExecutionAuthority',('SubagentJournal.swift','    mutating func retarget(_ sessionID: String) {','    mutating func retarget(_ sessionID: String) {\n        if '+active('checkpoint_authority')+' { cuts = nil }'))
case('v5_promotion',UNIT+'testLazyPromotionKeepsV4UntilFirstCutAndNeverDowngrades',('SessionJournal.swift','marker:JournalRecordKind.cutinMarker)','marker:'+active('v5_promotion')+' ? JournalRecordKind.codexMarker : JournalRecordKind.cutinMarker)'))
case('cancel_drain','loop:reasoning',('Providers.swift','delivery.resolve(.success(committed))','delivery.resolve(.success(committed))\n                                if '+active('cancel_drain')+' { stream.cancel() }'))
case('wait_for_drain','loop:reasoning',('Providers.swift','delivery.resolve(.success(committed))','if !'+active('wait_for_drain')+' { delivery.resolve(.success(committed)) }'))
case('suffix_context','loop:reasoning',('MailboxCutJournal.swift','boundary = context; event("message_end"); return rows[0]','if '+active('suffix_context')+' { try append(ChatMessage(role:"assistant",content:[textBlock("DISCARDED-SUFFIX")])) }; boundary = context; event("message_end"); return rows[0]'))
case('discarded_usage','loop:reasoning',('Providers.swift','let observed = profile.api == "openai-responses" &&','let observed = (!'+active('discarded_usage')+' || cutReply == nil) && profile.api == "openai-responses" &&'))
case('settled_twice',PERSIST+'testInterruptCancelsAnAlreadySealedRecipientsDrainAndSettlementIsIdempotent',('SessionRequestAdmission.swift','if let previous = accounting.attempts[attempt]?.contribution { return previous }','if let previous = accounting.attempts[attempt]?.contribution { if '+active('settled_twice')+' { try journal?.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":previous],flush:true) }; return previous }'))
case('interrupt_drain',PERSIST+'testInterruptCancelsAnAlreadySealedRecipientsDrainAndSettlementIsIdempotent',('MailboxCutJournal.swift','    func cancelMailboxDrains(source: String) {','    func cancelMailboxDrains(source: String) {\n        if '+active('interrupt_drain')+' { return }'))
case('delivery_before_sync','crash:delivery-ack-synced',('AgentSteeringMessaging.swift','        try await recipient.appendAgentDelivery(delivery,selected:selected)','        if '+active('delivery_before_sync')+' { delivery.committed = true; try await owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery) }\n        try await recipient.appendAgentDelivery(delivery,selected:selected)'))
case('delivery_id','crash:delivery-row-synced',('SessionAgentDelivery.swift','row.id = delivery.rowID','row.id = '+active('delivery_id')+' ? UUID().uuidString : delivery.rowID'))
case('retry_without_mail','loop:reasoning',('Providers.swift','let history=messages.filter(\\.replayEligible)','let history=messages.filter { $0.replayEligible && (!'+active('retry_without_mail')+' || $0.nativeAgentDelivery == nil) }'))
case('reasoning_is_final',PERSIST+'testCutIsNeitherAProducedFinalNorAFinalResult',('AgentCodexContext.swift','$0.nativeMailboxCut == nil &&','($0.nativeMailboxCut == nil || '+active('reasoning_is_final')+') &&'))
case('cut_final_result',PERSIST+'testCutIsNeitherAProducedFinalNorAFinalResult',('SessionAgentCommands.swift','$0.nativeMailboxCut == nil &&','($0.nativeMailboxCut == nil || '+active('cut_final_result')+') &&'))
case('reasoning_resume',UNIT+'testTypedCutMetadataSurvivesJournalAndDisplay',('SessionContinue.swift','tail.nativeMailboxCut?["version"].int == 1 ||','(tail.nativeMailboxCut?["version"].int == 1 && !'+active('reasoning_resume')+') ||'))
case('inherited_child_fence',PERSIST+'testInheritedChildAndKeptSideRequireV5WithoutInheritingCutAuthority',('AgentLegacyAdoption.swift','if seedMessages.contains(where:','if !'+active('inherited_child_fence')+', seedMessages.contains(where:'))
case('kept_side_fence',PERSIST+'testInheritedChildAndKeptSideRequireV5WithoutInheritingCutAuthority',('SessionPersistence.swift','let inheritedCuts = history.contains','let inheritedCuts = !'+active('kept_side_fence')+' && history.contains'))
case('ambiguous_commit_partial','failure:owner-commit-sync',('MailboxCutJournal.swift','await recipient.retireMailboxPartial()','if !'+active('ambiguous_commit_partial')+' { await recipient.retireMailboxPartial() }'))
case('message_shape',UNIT+'testMalformedMessageAndDuplicateCallIDsDoNotCut',('MailboxCut.swift','guard case .array = item["content"] else { return false }','if !'+active('message_shape')+' { guard case .array = item["content"] else { return false } }'))
case('duplicate_calls',UNIT+'testMalformedMessageAndDuplicateCallIDsDoNotCut',('MailboxCut.swift','guard Set(calls).count == calls.count else','guard '+active('duplicate_calls')+' || Set(calls).count == calls.count else'))
case('cut_version',PERSIST+'testPreparationDigestPairingStableIDsAndInheritedAuthorityFailClosed',('MailboxCutJournal.swift','first.nativeMailboxCut?["version"].int == 1,','('+active('cut_version')+' || first.nativeMailboxCut?["version"].int == 1),'))
case('cancellation_reason',PERSIST+'testPreparationDigestPairingStableIDsAndInheritedAuthorityFailClosed',('MailboxCutJournal.swift','result.nativeAgentCallCancellation?["reason"].text == "agent_message",','('+active('cancellation_reason')+' || result.nativeAgentCallCancellation?["reason"].text == "agent_message"),'))

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file)); result=importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--skip-build',action='store_true'); parser.add_argument('--cases',nargs='+'); parser.add_argument('--recovery',required=True)
    args=parser.parse_args(); source=BUILD/'cutin-mutation-source'; scratch=BUILD/'cutin-mutation-build'; logs=BUILD/'logs/cutin-mutations'; logs.mkdir(parents=True,exist_ok=True)
    base=['swift','test','--package-path',str(source),'--scratch-path',str(scratch),'-j','4']
    if not args.skip_build:
        prepared=module('cutin_crash','test-subagent-cutin-crashes.py').prepare()
        shutil.copytree(prepared,source,dirs_exist_ok=True)
        shutil.copytree(ROOT/'packages/swift-host/Tests',source/'Tests',dirs_exist_ok=True)
        core=source/'Sources/PiAgentCore'
        (core/'CutinMutation.swift').write_text('import Foundation\nenum CutinMutation { static func active(_ name: String) -> Bool { ProcessInfo.processInfo.environment["PI_CUTIN_MUTATION"] == name } }\n')
        for name,test,edits in CASES:
            for file,old,new in edits:
                path=core/file; text=path.read_text(); assert text.count(old)==1,(name,file,old,text.count(old)); path.write_text(text.replace(old,new))
        path=core/'MailboxCut.swift'; text=path.read_text().replace('        item["type"].text == "reasoning" ||','        return item["type"].text == "reasoning" ||')
        text=text.replace('return item["role"].text == "assistant" && ["commentary", "partial_answer"].contains(item["phase"].text ?? "")','return item["role"].text == "assistant" && ('+active('final_boundary')+' || '+active('unknown_phase')+' || ["commentary", "partial_answer"].contains(item["phase"].text ?? ""))')
        # replayItems supplies a second route fence; mutate it only for these two cases.
        text=text.replace('guard (try? replayItems(probe,profile:profile)) != nil else','guard '+active('route_policy')+' || '+active('route_identity')+' || (try? replayItems(probe,profile:profile)) != nil else')
        path.write_text(text)
        with (logs/'baseline.log').open('w') as log: subprocess.run(base+['--filter','MailboxCut'],stdout=log,stderr=subprocess.STDOUT,check=True)
    binary=scratch/'debug/pi-native-host'
    selected=[c for c in CASES if not args.cases or c[0] in args.cases]
    for name,test,_ in selected:
        if test.startswith(('loop:','crash:','failure:')):
            mode=test.split(':',1)[1]
            code="import importlib.util; s=importlib.util.spec_from_file_location('c','scripts/test-subagent-cutin.py'); c=importlib.util.module_from_spec(s); s.loader.exec_module(c); "
            if test.startswith('loop:'): code+=f"c.run({str(binary)!r},{mode!r})"
            else:
                argument='failure_point' if test.startswith('failure:') else 'crash_point'
                code+=f"c.run({str(binary)!r},'reasoning',{argument}={mode!r},recovery={args.recovery!r})"
            command=[sys.executable,'-c',code]
        else: command=base+['--skip-build','--filter',test]
        env=dict(os.environ,PI_CUTIN_MUTATION=name,NSUnbufferedIO='YES',PYTHONPATH=str(ROOT/'scripts'))
        with (logs/(name+'.log')).open('w') as log:
            result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=100)
        output=(logs/(name+'.log')).read_text()
        assert result.returncode != 0 and ('XCTAssert' in output or 'failed: caught error:' in output or 'AssertionError' in output or ' : failed - ' in output), (name,'SURVIVED/no assertion evidence')
        with (logs/(name+'-restored.log')).open('w') as log:
            restored=dict(env); restored.pop('PI_CUTIN_MUTATION')
            subprocess.run(command,env=restored,stdout=log,stderr=subprocess.STDOUT,timeout=100,check=True)
        print('CAUGHT AND RESTORED',name,test,flush=True)
    print(f'PASS {len(selected)} cut-in mutations',flush=True)

if __name__ == '__main__': main()
