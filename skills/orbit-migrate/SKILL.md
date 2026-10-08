---
name: orbit-migrate
description: Upgrade an existing Orbit vault to the installed release, inspect migration compatibility, or resume or roll back a migration. Selects version-specific instructions from the actual vault format and target release.
---

# Migrate Orbit

Use Orbit MCP tools. Discover `orbit_doctor`, `orbit_migrate`, `orbit_schema`,
`orbit_index`, `orbit_search`, and `orbit_read`. Missing tools mean the installed
plugin needs updating; do not substitute shell edits or manual file moves.

Use the bound vault. Never infer its location from a repository or create a new
vault to avoid a migration. If doctor reports no binding, reuse the user's explicit
vault path with `orbit_setup` and `create: false`; ask for that path if it is unknown.
Call doctor and read its migration state. The vault's
data format determines the route; the app release alone does not. Old vaults can
have an unknown source release. Preserve that uncertainty.

| Source format | Target format and release | Instructions |
|---|---|---|
| 1, including markers without data_format | 2 in Orbit 0.4.0 | [Format 1 to 2](references/format-1-to-2.md) |
| 2 | 2 in Orbit 0.4.0 | [Compatibility check](references/format-2-check.md) |
| Prepared migration | Recorded target | [Recovery](references/recovery.md) |
| Any other pair or downgrade | Unsupported | Stop and report the observed versions. Do not modify the marker to bypass routing. |

Read only the applicable reference. For an upgrade, call migrate with `action:
"plan"` and the target release. Review the returned moves, warnings, and exact
plan ID. Plan is read-only. A stale plan requires a new preview and review.

Apply only within an explicit request to migrate that vault. A request to install
or release the plugin does not authorize personal-vault migration. If migration
is already authorized and the plan fits its scope, proceed without another
confirmation. Report ambiguous projects, collisions, and unsupported links;
never guess a destination or delete a conflicting note.

After a committed migration, rebuild the index and verify note identities, links,
source preservation, schemas, and realistic recall at the new paths. Report
schema warnings and historical integration receipts needing re-verification.
Return source/target versions, the operation and backup path, and what was
verified. A subprocess check does not prove native desktop or fresh-chat behavior.

This is Orbit's only migration skill. Future releases add tested routes and
reference instructions here rather than another user-facing migration skill.
