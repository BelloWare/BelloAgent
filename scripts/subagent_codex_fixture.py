"""Generated-loopback helpers for the public v4 text envelope (no native IDs)."""
import re


def agent_events(body):
    events = []
    turns = {}
    for item in body.get('input', []):
        content = item.get('content', [])
        for block in content if isinstance(content, list) else []:
            text = block.get('text', '')
            pattern = r'(?:\A|(?<=\n\n))Message Type: (NEW_TASK|MESSAGE|FINAL_ANSWER)\nTask name: (/root(?:/[a-z0-9_]+)?)\nSender: (/root(?:/[a-z0-9_]+)?)\nPayload:\n((?:  [^\n]*(?:\n|$))+)'
            for match in re.finditer(pattern, text):
                kind, recipient, sender, payload = match.groups()
                lines = payload.removesuffix('\n').split('\n')
                assert all(line.startswith('  ') for line in lines)
                payload = '\n'.join(line[2:] for line in lines)
                if kind == 'FINAL_ANSWER': turns[sender] = turns.get(sender, 0) + 1
                events.append(dict(type=kind, recipient=recipient, sender=sender, text=payload,
                                   kind='result' if kind == 'FINAL_ANSWER' else 'question' if kind == 'MESSAGE' else 'task',
                                   child_id=sender, turn=turns.get(sender, 1)))
    return events
