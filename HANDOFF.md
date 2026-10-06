# Orbit handoff

Updated 2026-10-06. Orbit v0.2.0 prerelease.

## Scope

Keep skills plus deterministic Python helpers. No MCP, server, daemon, hooks or background capture.
The user authorized the Orbit rename and publication to public aataraxiaa/orbit.
Personal-vault migration remains separate from development and disposable-vault acceptance.
The public source repository is https://github.com/aataraxiaa/orbit.

## Modules

- scripts/orbit.py owns setup, config, safe paths, authoritative writes, read and recovery.
- scripts/retrieval.py owns a machine-local incremental FTS5 passage index, scoped ranking and current evidence checks.
- scripts/knowledge.py owns catalogs, explicit relationships, durable integration stages and maintenance diagnostics.
- scripts/eval.py evaluates labeled synthetic helper retrieval from tests/fixtures/retrieval.
- Four skills own source interpretation, useful map curation, knowledge integration and evidence-based answers.

The derived cache stays outside the synced vault, keyed to vault identity and canonical path.
Source integration records stay in .orbit/integrations for new vaults, or the existing legacy state directory. They survive cache loss.
Metadata fields and note prose remain user-owned. Unknown metadata blocks must remain verbatim.
Sources/assets originals cannot participate as canonical identities or ordinary indexed search results.

## Verification and limitations

Read current test/evaluation and host receipts in the project artifact directory printed by
~/.agents/bin/agent-task-dir, under review-artifacts/v2/. The plan is review-artifacts/v2-plan.md.
Do not infer successful LLM or GUI behavior from passing helper tests.
QMD 2.8.3 was installed only in task artifacts for comparison. Embedding/model-context initialization
failed on this host. QMD is not a plugin dependency; lexical search remains the validated built-in mode.
Do not claim semantic matching, arbitrary YAML support, whole-vault transactions, or universal host acceptance.

Run python3 -m unittest discover -s tests -v, python3 scripts/smoke.py and python3 scripts/package.py
before handing off a changed artifact. Use disposable vaults with isolated ORBIT_CONFIG and ORBIT_CACHE.
