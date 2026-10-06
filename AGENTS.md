# Project instructions

Read HANDOFF.md and LOCAL_TEST.md first. This is the Orbit plugin.
Keep it skills plus deterministic Python scripts. No MCP, hooks, daemon, or backend.
Publication is authorized to public aataraxiaa/orbit for this release.
Use a disposable vault and isolated ORBIT_CONFIG and ORBIT_CACHE for tests; never infer the user's
vault or code-directory location. Preserve unknown note fields and user-written content.
Run `python3 -m unittest discover -s tests -v`, `python3 scripts/smoke.py`, and rebuild
with `python3 scripts/package.py` before handing off a changed installable artifact.
Distinguish mechanical test results from untested real-host/LLM behavior.
