#!/usr/bin/env python3
"""Fixed, generated close/reap fixture. No arbitrary command execution."""
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('fixture','/workspace/shared/agent-shell-stage/rust/fixtures/bash_workflow_fixture.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
# Relative paths refer only to the fresh generated project. TERM is recorded but
# does not finish the loop; owned KILL escalation must settle it on app close.
# Without cancellation the loop self-terminates in at most about 90 seconds.
m.COMMANDS={'BASH_HELD':("trap 'printf term > held.term' TERM; printf '%s\\n' \"$$\" > held.pid; cat /proc/$$/stat > held.startstat; printf ready > held.ready; printf 'held close fixture ready\\n'; for i in {1..900}; do [ -e held.release ] && break; sleep 0.1; done; printf finished > held.finished",120)}
if __name__=='__main__':m.main()
