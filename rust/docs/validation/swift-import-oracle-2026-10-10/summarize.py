import json, sys
for s in json.load(open("journals/scenarios.json")):
    d = json.load(open(f"journals/{s}.swift.json"))
    print("==", s, len(d["visible"]), "visible, context", len(d["context"]), "parent", bool(d["parent"]))
    for r in d["visible"]:
        extra = []
        for k in ["kind", "toolCalls", "toolCallId", "isError", "detail", "stopReason"]:
            if k in r and r[k] not in (False, None):
                extra.append(k + "=" + json.dumps(r[k])[:60])
        print("  ", r["role"], repr(r["text"][:50]), " ".join(extra))
