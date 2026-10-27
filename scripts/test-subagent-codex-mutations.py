#!/usr/bin/env python3
"""Compile fixture-only v4 guard mutations, then require assertion failures.

No production fault switches. All sources, binaries and logs stay under the
caller's PI_BUILD_ROOT. Run after the focused unmodified helper tests pass.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
CONTRACT = 'SubagentCodexContractTests/'
RUNTIME = 'AgentCodexRuntimeTests/testForkAcceptanceWholeResultsIdleMailAndFollowup'
MESSAGES = 'AgentCodexMessagingTests/'
PERSIST = 'AgentCodexPersistenceTests/'
CASES = []

def case(name, test, *edits):
    CASES.append((name, test, edits))

def enabled(name):
    return f'FixtureCodexMutation.active("{name}")'

case('name_resolution', CONTRACT+'testNamesAndAddressing', ('SubagentCodexContract.swift', 'if target == "/root" { return owner }', 'if target == "/root" { return '+enabled('name_resolution')+' ? "wrong-owner" : owner }'))
case('name_unique', CONTRACT+'testNamesAndAddressing', ('SubagentCodexContract.swift','guard !names.values.contains(path) else','guard '+enabled('name_unique')+' || !names.values.contains(path) else'))
case('root_spawn', MESSAGES+'testSiblingMessagesTasksAndRootOnlySpawn',
     ('AgentCodexCommands.swift','guard call.name != "spawn_agent" else','guard '+enabled('root_spawn')+' || call.name != "spawn_agent" else'),
     ('AgentCodexCommands.swift','guard source == nil else','guard '+enabled('root_spawn')+' || source == nil else'))
case('fork_boundary',RUNTIME,('AgentCodexContext.swift','let messages = seed.messages.map','let messages = ('+enabled('fork_boundary')+' ? context : seed.messages).map'))
case('fork_consent', CONTRACT+'testInheritedRowsStripConsentAndKeepContent',('SubagentCodexContract.swift','row.userInput = nil','if !'+enabled('fork_consent')+' { row.userInput = nil }'))
case('fork_cache', RUNTIME,('SessionSide.swift','{ return cache }','{ return '+enabled('fork_cache')+' ? id : cache }'))
case('fork_prompt', RUNTIME,('AgentSteeringCoordinator.swift','if codex == nil {','if codex == nil || '+enabled('fork_prompt')+' {'))
case('fork_tools', RUNTIME,('SessionTools.swift','{ return frozen.tools }','{ return '+enabled('fork_tools')+' ? Array(frozen.tools.dropLast()) : frozen.tools }'))
case('envelope_indent',CONTRACT+'testEnvelopeIndentsEveryPayloadLineAndV2RoundTrips',('SubagentCodexContract.swift','.map { "  " + $0 }','.map { ('+enabled('envelope_indent')+' ? "" : "  ") + $0 }'))
case('sibling_message',MESSAGES+'testSiblingMessagesTasksAndRootOnlySpawn',('AgentCodexCommands.swift','case "send_message", "followup_task":','case "send_message", "followup_task":\n            if '+enabled('sibling_message')+', source != nil, call.name == "send_message" { throw AgentError("fixture_mutation","Sibling mail disabled") }'))
case('sibling_task',MESSAGES+'testSiblingMessagesTasksAndRootOnlySpawn',('AgentCodexCommands.swift','case "send_message", "followup_task":','case "send_message", "followup_task":\n            if '+enabled('sibling_task')+', source != nil, call.name == "followup_task" { throw AgentError("fixture_mutation","Sibling tasks disabled") }'))
case('idle_closure',RUNTIME,('SessionAgentDelivery.swift','!($0.queueOnly == true && $0.recipientChildID != nil)','('+enabled('idle_closure')+' || !($0.queueOnly == true && $0.recipientChildID != nil))'))
case('final_deferral',MESSAGES+'testFinalDefersQueueOnlyMailWithoutAnotherRequest',('AgentSteeringMessaging.swift','deferMail:final && lease.taskName != nil','deferMail:!'+enabled('final_deferral')+' && final && lease.taskName != nil'))
case('whole_final',RUNTIME,('AgentFamilyRecovery.swift','case .completed: text = full','case .completed: text = '+enabled('whole_final')+' ? String(full.prefix(8192)) : full'))
case('every_turn',RUNTIME,('AgentFamilyRecovery.swift','let full = turn.result?.envelope["text"].text ?? "", reason =','let full = '+enabled('every_turn')+' && turn.turn > 1 ? "" : (turn.result?.envelope["text"].text ?? ""), reason ='))
case('wait_bounds',CONTRACT+'testPromptsAndWaitBounds',('SubagentCodexContract.swift','max(10000,args["timeout_ms"].int ?? 30000)','max('+enabled('wait_bounds')+' ? 0 : 10000,args["timeout_ms"].int ?? 30000)'))
case('wait_upper',CONTRACT+'testPromptsAndWaitBounds',('SubagentCodexContract.swift','guard SubagentSteeringContract.matches(args,schema),','if '+enabled('wait_upper')+', name == "wait_agent" { schema["properties"]["timeout_ms"] = ["type":"integer"] }\n        guard SubagentSteeringContract.matches(args,schema),'))
for mutation, old in [('wait_mail','"Wait completed: updates from " + names.joined(separator:", ") + "."'),('wait_steer','"Wait interrupted by new input."'),('wait_stop','"Wait interrupted by Stop."'),('wait_cost','"Wait interrupted by cost limit."')]:
    case(mutation,MESSAGES+'testWaitMailboxSteerStopCostAndTimeout',('AgentCodexStatus.swift','answer = '+old,'answer = '+enabled(mutation)+' ? "Wait timed out." : '+old))
case('interrupt_note',MESSAGES+'testRootInterruptSuppressesResultAndNextTaskCarriesNote',('AgentCodexCommands.swift','if let who = latest.interruptedBy {','if let who = latest.interruptedBy, !'+enabled('interrupt_note')+' {'))
case('name_adoption',PERSIST+'testV3NamesAdoptOnceWithLifetimeUniquenessAndCheckpointReplay',('AgentCodexContext.swift','if changed { try journal?.promoteToCodex','if changed && !'+enabled('name_adoption')+' { try journal?.promoteToCodex'))
case('marker_promotion', 'AgentCodexRuntimeTests/testNewRunAdvertisesV4AndPromotesMarker',('SessionJournal.swift','marker:JournalRecordKind.codexMarker)','marker:'+enabled('marker_promotion')+' ? JournalRecordKind.steeringMarker : JournalRecordKind.codexMarker)'))
case('fork_publication_repair',PERSIST+'testPartialForkPublicationRecoversNotExecutedAndNoConsent',('AgentFamilyRecovery.swift','if exists, !seedComplete, let seed = plan.forkSeed {','if exists, !seedComplete, let seed = plan.forkSeed, !'+enabled('fork_publication_repair')+' {'))
case('parent_stop',MESSAGES+'testParentHumanStopRecordsTheInitiator',('Sessions.swift','if userInitiated { recordAgentUserStop() }','if userInitiated && !'+enabled('parent_stop')+' { recordAgentUserStop() }'))
case('late_interrupt_note',PERSIST+'testLateMirrorsKeepInterruptNotesAndUndeliveredTasksStayTyped',('AgentFamilyJournal.swift','if turn.interruptedBy == nil { turn.interruptedBy = old.interruptedBy }','if turn.interruptedBy == nil && !'+enabled('late_interrupt_note')+' { turn.interruptedBy = old.interruptedBy }'))
case('undelivered_envelope',PERSIST+'testLateMirrorsKeepInterruptNotesAndUndeliveredTasksStayTyped',('AgentFamilyRecovery.swift','if message.type != nil {','if message.type != nil && !'+enabled('undelivered_envelope')+' {'))
case('idle_v2_interrupt',PERSIST+'testInterruptOfNamedIdleV2AgentSucceedsWithoutAdoptingATurn',('AgentCodexCommands.swift','guard let latest = state.latest(target) else {','guard let latest = state.latest(target) else {\n                if '+enabled('idle_v2_interrupt')+' { throw AgentError("agent_not_found","Old rejection") }'))
case('publication_closure','AgentCodexRuntimeTests/testFailedChildPublicationDisposesItsTaskAndLetsFamilyClose',('AgentSteeringCoordinator.swift','try await seal(turn:failed,parent:parent,task:plan.origin.description,child:nil)','if '+enabled('publication_closure')+' { try await parent.appendAgentRecord(JournalRecordKind.agentTerminal,failed) } else { try await seal(turn:failed,parent:parent,task:plan.origin.description,child:nil) }'))
case('publication_request_fence',PERSIST+'testPartialForkPublicationRecoversNotExecutedAndNoConsent',('AgentCodexContext.swift','guard complete(rows:rows,reference:saved) else','guard '+enabled('publication_request_fence')+' || complete(rows:rows,reference:saved) else'))
for mutation, limit in [('eight_events',8),('one_message',1)]:
    case(mutation,'AgentCodexDeliveryTests/testAllFittingMessagesDeliverInOneFairRowWithoutOldCaps',('AgentSteeringMessaging.swift','        var body = payload(selected)','        if '+enabled(mutation)+' { selected = Array(selected.prefix('+str(limit)+')) }\n        var body = payload(selected)'))
case('byte_cap','AgentCodexDeliveryTests/testAllFittingMessagesDeliverInOneFairRowWithoutOldCaps',('AgentSteeringMessaging.swift','        var body = payload(selected)','        if '+enabled('byte_cap')+' { while selected.count > 1 && payload(selected).encoded().utf8.count > 16384 { selected.removeLast() } }\n        var body = payload(selected)'))
case('sender_fairness','AgentCodexDeliveryTests/testAllFittingMessagesDeliverInOneFairRowWithoutOldCaps',('AgentSteeringMessaging.swift','        var body = payload(selected)','        if '+enabled('sender_fairness')+' { selected.sort { $0.sequence < $1.sequence } }\n        var body = payload(selected)'))
case('context_fit','AgentCodexDeliveryTests/testContextCapacityStillRejectsWholeOversizeMessage',('SessionAgentDelivery.swift','return try countContext(messages,request:body).fits','return try ('+enabled('context_fit')+' || countContext(messages,request:body).fits)'))
case('delivered_turn',RUNTIME,('AgentFamilyJournal.swift','if let deliveredTurn = delivery.eventTurns?[id] {','if let deliveredTurn = delivery.eventTurns?[id], !'+enabled('delivered_turn')+' {'))
case('frozen_v3_pause','AgentCodexRuntimeTests/testPausedV3RunKeepsItsContractUntilAFreshTask',('SessionAgentCommands.swift','agentContractVersion = codex && !legacyPause ? 4 : 3','agentContractVersion = codex && (!legacyPause || '+enabled('frozen_v3_pause')+') ? 4 : 3'))
case('report_caps'     ,'AgentMailboxPolicyTests/testPendingReportsAndRateHaveNoSmallLimits',('AgentMailboxPolicy.swift','static func validate(_ op: AgentOperation, state: AgentFamilyState) throws {','static func validate(_ op: AgentOperation, state: AgentFamilyState) throws {\n        if '+enabled('report_caps')+', state.messages.count >= 4 { throw AgentError("fixture_mutation","Old pending cap") }'))

FORK = PERSIST+'testForkPublicationChecksReferenceOrderAndRoundTripDigest'
RECOVERY = PERSIST+'testForkRecoveryUsesReopenedParentContextAndFailsClosedOnChangedOrMissingRows'
PAUSE = 'FamilyLimitPauseTests/testV4ForkResumeKeepsTurnSeedAndTaskAndDeliversWholeFinal'
case('fork_body_transport',RUNTIME,('AgentCodexCommands.swift','parent:owner,seedMessages:seedMessages)','parent:owner,seedMessages:'+enabled('fork_body_transport')+' ? [] : seedMessages)'))
case('fork_reference',FORK,
     ('AgentCodexContext.swift','saved == reference && matches','('+enabled('fork_reference')+' || saved == reference) && matches'),
     ('AgentCodexContext.swift','guard row["data"] == reference else','guard '+enabled('fork_reference')+' || row["data"] == reference else'))
case('fork_digest',FORK,('AgentCodexContext.swift','Self.contentDigest(messages) == digest','('+enabled('fork_digest')+' || Self.contentDigest(messages) == digest)'))
case('fork_order',FORK,('AgentCodexContext.swift','matches(Array(rows.prefix(ids.count)))','matches('+enabled('fork_order')+' ? Array(rows.prefix(ids.count)).sorted { ids.firstIndex(of:$0.id)! < ids.firstIndex(of:$1.id)! } : Array(rows.prefix(ids.count)))'))
case('fork_body_exclusion',PERSIST+'testForkReferenceExcludesBodiesFromOperationsAndCheckpoint',
     ('AgentCodexContext.swift','    var digest: String\n','    var digest: String\n    var fixtureBodies: [ChatMessage]?\n'),
     ('AgentCodexContext.swift','case from, cutoffEntryID = "cutoffEntryId", ids, digest','case from, cutoffEntryID = "cutoffEntryId", ids, digest, fixtureBodies'),
     ('AgentCodexContext.swift','ids = messages.map(\\.id); digest = Self.contentDigest(messages)','ids = messages.map(\\.id); digest = Self.contentDigest(messages); fixtureBodies = '+enabled('fork_body_exclusion')+' ? messages : nil'))
case('fork_parent_digest',RECOVERY,('AgentCodexContext.swift','guard matches(messages) else','guard '+enabled('fork_parent_digest')+' || matches(messages) else'))
case('fork_parent_missing',RECOVERY,('AgentCodexContext.swift','guard '+enabled('fork_parent_digest')+' || matches(messages) else','guard '+enabled('fork_parent_digest')+' || '+enabled('fork_parent_missing')+' && messages.count < ids.count || matches(messages) else'))
case('fork_followup_fence',RECOVERY,('AgentCodexCommands.swift','if let seed = saved.forkSeed {','if let seed = saved.forkSeed, !'+enabled('fork_followup_fence')+' {'))
case('checkpoint_v2','JournalCheckpointTests/testAChatOpensFromItsMetadataFileAsAFullReplayWould',('JournalCheckpoint.swift','static let currentVersion = 2','static let currentVersion = '+enabled('checkpoint_v2')+' ? 3 : 2'))
case('checkpoint_family_gate','JournalCheckpointTests/testFamilyScopedMarkersRejectOldDerivedStateOnlyForFamilies',('SessionCheckpointing.swift','guard (saved["subagentEffortVersion"].int == 1','guard '+enabled('checkpoint_family_gate')+' || (saved["subagentEffortVersion"].int == 1'))
case('child_sender',MESSAGES+'testMissingChildSenderNameFailsClosed',('AgentCodexCommands.swift','guard let name = names[source.childID] else','guard let name = names[source.childID] ?? ('+enabled('child_sender')+' ? "/root" : nil) else'))
for key, scalar in [('envelope_vtab','000B'),('envelope_formfeed','000C')]:
    case(key,CONTRACT+'testEnvelopeIndentsEveryCharacterSetNewline',('SubagentCodexContract.swift','.replacingOccurrences(of:"\\u{'+scalar+'}",with:"\\n")','.replacingOccurrences(of:'+enabled(key)+' ? "never-fixture-newline" : "\\u{'+scalar+'}",with:"\\n")'))
case('v4_resume_task',PAUSE,('SessionAgentCommands.swift','if history.contains(where: { $0.id == turn.inputID }) { return .delivered }','if '+enabled('v4_resume_task')+' { return .fresh }; if history.contains(where: { $0.id == turn.inputID }) { return .delivered }'))
case('v4_pause_final',PAUSE,('AgentFamilyRecovery.swift','case .completed: text = '+enabled('whole_final')+' ? String(full.prefix(8192)) : full','case .completed: text = ('+enabled('whole_final')+' || '+enabled('v4_pause_final')+') ? String(full.prefix(8192)) : full'))
case('v4_pause_idle_mail',PAUSE,('SessionAgentDelivery.swift','('+enabled('idle_closure')+' || !($0.queueOnly == true && $0.recipientChildID != nil))','('+enabled('idle_closure')+' || '+enabled('v4_pause_idle_mail')+' || !($0.queueOnly == true && $0.recipientChildID != nil))'))
case('v4_resume_seed',PAUSE,('AgentSteeringCoordinator.swift','            if job.resuming {','            if job.resuming {\n                if '+enabled('v4_resume_seed')+', let seed = job.plan.forkSeed { try await child.appendAgentRecord(JournalRecordKind.agentForkSeed,seed.reference) }'))
case('fork_recovery_completeness',PERSIST+'testPartialForkPublicationRecoversNotExecutedAndNoConsent',('AgentFamilyRecovery.swift','let seedComplete = plan.forkSeed.map { $0.complete(rows:orderedRows,reference:seedReference) } ?? true','let seedComplete = '+enabled('fork_recovery_completeness')+' || (plan.forkSeed.map { $0.complete(rows:orderedRows,reference:seedReference) } ?? true)'))
case('fork_recovery_inherited',RECOVERY,('AgentCodexContext.swift','let messages = context[..<boundary].map { SubagentCodexContract.inherited($0,from:from,cutoff:cutoffEntryID) }','let messages = '+enabled('fork_recovery_inherited')+' ? Array(context[..<boundary]) : context[..<boundary].map { SubagentCodexContract.inherited($0,from:from,cutoff:cutoffEntryID) }'))
case('v4_pause_stop','FamilyLimitPauseTests/testV4WholeChatStopDuringPauseRecordsTheUser',('SessionAgentCommands.swift','if costPaused || costResumePending {\n                for var turn','if (costPaused || costResumePending) && !'+enabled('v4_pause_stop')+' {\n                for var turn'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build',action='store_true')
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--cases',nargs='+',choices=[x[0] for x in CASES])
    args = parser.parse_args()
    source, scratch, logs = BUILD/'codex-mutation-source', BUILD/'codex-mutation-build', BUILD/'logs/codex-mutations'
    logs.mkdir(parents=True,exist_ok=True)
    base = ['swift','test','--package-path',str(source),'--scratch-path',str(scratch)]
    if not args.skip_build:
        shutil.copytree(ROOT/'packages/swift-host',source,ignore=shutil.ignore_patterns('.build','.swiftpm'),dirs_exist_ok=True)
        core = source/'Sources/PiAgentCore'
        (core/'FixtureCodexMutation.swift').write_text('import Foundation\nenum FixtureCodexMutation { static func active(_ key: String) -> Bool { ProcessInfo.processInfo.environment["PI_CODEX_MUTATION"] == key } }\n')
        for name, test, edits in CASES:
            for filename, old, new in edits:
                path = core/filename; text = path.read_text()
                assert text.count(old) == 1, (name,filename,old,text.count(old))
                path.write_text(text.replace(old,new))
        if args.prepare_only:
            print(f'Prepared {len(CASES)} fixture-only mutations'); return
        with (logs/'baseline.log').open('w') as log:
            subprocess.run(base+['--filter','AgentCodex|SubagentCodexContract|AgentMailboxPolicy|FamilyLimitPauseTests/testV4'],stdout=log,stderr=subprocess.STDOUT,check=True)
    selected = [x for x in CASES if not args.cases or x[0] in args.cases]
    for name, test, _ in selected:
        path = logs/(name+'.log')
        with path.open('w') as log:
            result = subprocess.run(base+['--skip-build','--filter',test],env=dict(os.environ,PI_CODEX_MUTATION=name),stdout=log,stderr=subprocess.STDOUT,timeout=120)
        output = path.read_text()
        assert result.returncode != 0 and 'Executed 0 tests' not in output and ('XCTAssert' in output or 'failed: caught error:' in output), (name,'mutation survived or no assertion evidence',path)
        with (logs/(name+'-restored.log')).open('w') as log:
            subprocess.run(base+['--skip-build','--filter',test],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
        print('CAUGHT AND RESTORED',name,test,flush=True)
    print(f'PASS {len(selected)} guard mutations caught',flush=True)

if __name__ == '__main__': main()
