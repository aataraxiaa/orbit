---
name: orbit-maintain
description: Explicitly review or repair Orbit, correct saved knowledge, find meaningful connections, inspect duplicate notes, update topic maps, or recover an interrupted save. No scheduled or background maintenance.
---

# Maintain Orbit

Use Orbit's MCP tools for all vault operations. Discover the callable tools first.
If unavailable, report the connection failure and use the setup skill; do not fall
back to shell commands. Unprefixed operation names below mean the `orbit_` MCP tools.

Read [format](../../references/format.md) and [tools](../../references/tools.md).
Scope work to the user's request. Run maintain for bounded integration and provenance
signals; run catalog and relations for navigation and recorded relationship evidence.
Read reported paths before proposing semantic corrections. Run doctor for structural problems; search and read
for semantic issues. Separate a diagnostic report from changes the user requested.

- Connections: compare actual claims, explain why a relationship matters, and label
  speculative associations. Update relevant maps only when they improve navigation.
- Corrections: preserve the source/history of the prior statement; distinguish a typo,
  an updated fact, and a disputed interpretation. Use read hashes and apply.
- Duplicates: compare identity, context, sources, and aliases before proposing a merge.
  No delete/rename tool is shipped. Preserve both files unless the user explicitly
  requests a destructive cleanup; for a routine consolidation, leave a redirect note
  with its original stable id and a link to the canonical note.
- Orphans: unlinked does not automatically mean bad. Connect only where meaningful.
- Interrupted saves: follow recovery instructions. Never auto-remove a possibly active
  write lock or overwrite changes made after an interrupted operation.
- Setup/access issues: use setup skill; do not solve a missing permission with a second,
  accidental vault or broad sandbox disablement.

A report should name concrete findings and affected paths, the changes actually applied,
and any remaining issues. Mechanical validation does not prove factual correctness.

Resume incomplete integrations from their durable records. Keep operation recovery
separate from semantic processing. Rebuild a corrupt search cache with `orbit_index` with `rebuild: true`;
never repair it by rewriting authoritative notes. Review only affected maps and claims.
