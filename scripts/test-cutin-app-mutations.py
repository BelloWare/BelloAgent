#!/usr/bin/env python3
"""Temporary app mutations; always restore sources, then rebuild the same test host."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ['PI_BUILD_ROOT'])
APP = ROOT/'apps/macos/PiApp'
LOGS = BUILD/'logs/cutin-app-mutations'
LOGS.mkdir(parents=True,exist_ok=True)
def flag(name): return f'MailboxCutPresentation.fixtureMutation("{name}")'
cases = [
 ('capability','MailboxCutPresentationTests/testMarkerRequiresCapabilityAndKnownTypedVersion','Transcript/MailboxCutPresentation.swift','row.mailboxCutin == true,','(row.mailboxCutin == true || '+flag('capability')+'),'),
 ('version','MailboxCutPresentationTests/testMarkerRequiresCapabilityAndKnownTypedVersion','Transcript/MailboxCutPresentation.swift','row.nativeMailboxCut?.object?["version"]?.number == 1 else','(row.nativeMailboxCut?.object?["version"]?.number == 1 || '+flag('version')+') else'),
 ('cancelled_card','MailboxCutPresentationTests/testCancelledCallUsesTypedStateAndInspectableResult','Transcript/MailboxCutPresentation.swift','guard tool.mailboxCutin,','guard !'+flag('cancelled_card')+', tool.mailboxCutin,'),
 ('history','MailboxCutPresentationTests/testHistoryRetainsCutAndCancellationMetadata','Transcript/TranscriptMessage.swift','result.nativeMailboxCut = message["nativeMailboxCut"].flatMap { $0 == .null ? nil : $0 }','result.nativeMailboxCut = '+flag('history')+' ? nil : message["nativeMailboxCut"].flatMap { $0 == .null ? nil : $0 }'),
 ('receiving','MailboxCutPresentationTests/testDisplayCapabilityAndTransientStatus','Inspector/MetricsFooterView.swift','if session.supportsMailboxCutin, session.receivingAgentMessage','if !'+flag('receiving')+', session.supportsMailboxCutin, session.receivingAgentMessage'),
 ('static_marker','MailboxCutPresentationTests/testPermanentCutMarkerHasNoActivitySpinner','Transcript/TranscriptNativeMessageRow.swift','private var isCut: Bool { MailboxCutPresentation.marker(message) != nil }','private var isCut: Bool { !'+flag('static_marker')+' && MailboxCutPresentation.marker(message) != nil }'),
 ('status_publication','SubagentSteeringPresentationTests/testStableAgentRunStateDoesNotRepublishTheShellAndChangesStillArrive','Workspaces/SessionDisplay.swift','if receivingAgentMessage != receiving {','if receivingAgentMessage != receiving || '+flag('status_publication')+' {')
]
originals={APP/c[2]:(APP/c[2]).read_text() for c in cases}
base=['xcodebuild','-project','PiApp.xcodeproj','-scheme','PiApp','-destination','platform=macOS,arch=arm64','-derivedDataPath',str(BUILD/'native-tests'),'-jobs','4','OTHER_SWIFT_FLAGS=$(inherited) -driver-batch-count 4','CODE_SIGN_IDENTITY=-','CODE_SIGNING_REQUIRED=NO','COMPILER_INDEX_STORE_ENABLE=NO','-parallel-testing-enabled','NO']
selectors=['-only-testing:PiAppTests/MailboxCutPresentationTests','-only-testing:PiAppTests/SubagentSteeringPresentationTests']
def run(name,args,env=None):
    with (LOGS/(name+'.log')).open('w') as log: return subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
try:
    path=APP/'Transcript/MailboxCutPresentation.swift'
    path.write_text(path.read_text().replace('enum MailboxCutPresentation {','enum MailboxCutPresentation {\n    static func fixtureMutation(_ name: String) -> Bool { ProcessInfo.processInfo.environment["PI_APP_CUTIN_MUTATION"] == name }'))
    for name,test,file,old,new in cases:
        path=APP/file; source=path.read_text(); assert source.count(old)==1,(name,source.count(old)); path.write_text(source.replace(old,new))
    assert run('baseline',base+['test']+selectors).returncode == 0,'Mutation fixture did not pass unchanged'
    for name,test,*_ in cases:
        result=run(name,base+['test-without-building','-only-testing:PiAppTests/'+test],dict(os.environ,TEST_RUNNER_PI_APP_CUTIN_MUTATION=name))
        output=(LOGS/(name+'.log')).read_text()
        assert result.returncode != 0 and 'XCTAssert' in output and 'Executed 0 tests' not in output,(name,'SURVIVED/no assertion evidence')
        print('CAUGHT',name,test,flush=True)
finally:
    for path,original in originals.items(): path.write_text(original)
assert run('restored',base+['test']+selectors).returncode == 0,'Restored app did not pass'
print(f'PASS {len(cases)} app mutations; sources restored and {len(selectors)} classes green',flush=True)
