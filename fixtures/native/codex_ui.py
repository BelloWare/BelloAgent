"""Deterministic v4 app integration over the real helper, loopback only."""
import re
import time
from pathlib import Path


def events(text):
    pattern = r'(?:\A|(?<=\n\n))Message Type: (NEW_TASK|MESSAGE|FINAL_ANSWER)\nTask name: (/root(?:/[a-z0-9_]+)?)\nSender: (/root(?:/[a-z0-9_]+)?)\nPayload:\n((?:  [^\n]*(?:\n|$))+)'
    return [(kind, recipient, sender, '\n'.join(line[2:] for line in payload.rstrip('\n').split('\n')))
            for kind, recipient, sender, payload in re.findall(pattern, text)]


def wait_for(name):
    Path(name + '-waiting').touch()
    deadline = time.monotonic() + 45
    while not Path(name).exists() and time.monotonic() < deadline:
        time.sleep(.01)


def response(body, contract):
    texts = []
    for item in body.get('input', []):
        if item.get('role') != 'user':
            continue
        content = item.get('content', [])
        texts.append(content if isinstance(content, str) else '\n'.join(block.get('text', '') for block in content))
    deliveries = [event for text in texts for event in events(text)]
    tasks = [event for event in deliveries if event[0] == 'NEW_TASK']
    calls = list(contract['calls'].values())
    # This fixture seeds ordinary prose only, so a saved send belongs to
    # the audit turn.
    sent = any(call['name'] == 'send_message' for call in calls)
    if tasks and tasks[-1][1] == '/root/audit':
        if not sent:
            wait_for('release-audit')
            return 'send_message', {'target': '/root/tests', 'message': 'Queued sibling **finding**.'}, ''
        return None, {}, ('## Audit findings\n\nThe writer lock is **held**.\n\n' * 300) + 'FINAL-ANSWER-TAIL'
    if tasks and tasks[-1][1] == '/root/tests':
        if tasks[-1][3] == 'codex tests followup':
            return None, {}, 'CODEX-FOLLOWUP-STREAM'
        return None, {}, '**Tests ready.**'
    if 'codex app follow up' in texts:
        if not any(call['name'] == 'followup_task' for call in calls):
            return 'followup_task', {'target': '/root/tests', 'message': 'codex tests followup'}, ''
        if not any(call['name'] == 'interrupt_agent' for call in calls):
            wait_for('release-interrupt')
            return 'interrupt_agent', {'target': '/root/tests'}, ''
        return None, {}, 'Interrupted tests; the agent remains available.'
    if 'codex app family' not in texts:
        return None
    spawns = [call for call in calls if call['name'] == 'spawn_agent']
    if len(spawns) == 0:
        return 'spawn_agent', {'task_name': 'audit', 'message': 'codex audit task', 'fork_turns': 'all'}, ''
    if len(spawns) == 1:
        return 'spawn_agent', {'task_name': 'tests', 'message': 'codex tests task', 'fork_turns': 'none'}, ''
    if not any(call['name'] == 'list_agents' for call in calls):
        return 'list_agents', {}, ''
    if not any(call['name'] == 'wait_agent' for call in calls):
        return 'wait_agent', {}, ''
    return None, {}, 'Parent collected the agent updates.'
