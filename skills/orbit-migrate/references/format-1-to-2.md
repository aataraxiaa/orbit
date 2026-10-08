# Format 1 to format 2

Target Orbit 0.4.1. A marker without data_format is format 1; its exact originating
release may be unknown. The engine routes by format and refuses other targets.

The preview uses explicit note types and project identities, including the single
project field declared by a project note. A shared label must resolve uniquely;
title, ID, path and alias matches remain supported. Do not rename valid notes to
work around a missing project-field match in Orbit 0.4.0; update the plugin first. Projects move to
Projects/<project>/Overview.md. Their decisions and sessions move beneath that
project. People, sources, maps, schemas, and reusable knowledge use the standard
top-level folders. Untyped notes remain intact and are reported for classification.
Missing or ambiguous project ownership blocks the plan. Read the relevant notes
and resolve ownership from evidence within the user's authorization before retrying.

The engine repairs supported wikilinks and relative Markdown links, including
asset references. It preserves original assets, stable IDs, unknown metadata,
and prose apart from link tokens. Unsupported link forms or metadata references
that would break are explicit blockers. Do not work around them with broad text
replacement. Historical operation receipts remain unchanged; affected source
integration receipts are flagged for re-verification.

Call `orbit_migrate` with `action: "apply"`, `target_version: "0.4.1"`, and the
preview's `plan_id`. It rechecks the plan under the vault writer lock and saves
exact before-images in a durable migration journal before changing files. Keep
that journal as the recoverable backup. It contains private note content.

After commit, call `orbit_index` with `rebuild: true`, doctor, and schema. Use
catalog and targeted searches to confirm relocated notes and read their current
content. Cache failure is a retryable indexing problem; do not repeat a committed
migration to repair SQLite. A repeated plan verifies format-2 compatibility.

Existing vault-rule prose is preserved. The format-2 folder contract supersedes
old folder defaults; other user instructions and annotations remain intact.
