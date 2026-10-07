# Project instructions

Read HANDOFF.md and LOCAL_TEST.md first. This is the Orbit plugin.
The target is marketplace-plugin installation in the ChatGPT/Codex desktop app and
the Claude desktop app, including Cowork. CLI support is not an acceptance target.
The user authorized MCP-backed plugins on 2026-10-07, superseding the earlier no-MCP rule.
Preserve the existing Python storage engine and Markdown vault contract. Prove native
plugin connection, save/read across apps, and fresh-conversation persistence before
claiming desktop support. CLI and mechanical tests are separate evidence.
Publication is authorized to public aataraxiaa/orbit for this release.
Use a disposable vault and isolated ORBIT_CONFIG and ORBIT_CACHE for tests; never infer the user's
vault or code-directory location. Preserve unknown note fields and user-written content.
Run `python3 -m unittest discover -s tests -v`, `python3 scripts/smoke.py`, and rebuild
with `python3 scripts/package.py` before handing off a changed installable artifact.
Distinguish mechanical test results from untested real-host/LLM behavior.
