---
name: orbit-setup
description: Set up Orbit, choose or create an Obsidian vault, connect this agent to it, switch vaults, or diagnose access from a fresh conversation. Use only for explicit setup or access repair.
---

# Set up Orbit

Connect this host through Orbit's MCP tools and prove it can save and retrieve a note.
Read [host setup](../../references/setup.md) and [tools](../../references/tools.md).

1. Discover Orbit's MCP tools and call `orbit_doctor`. If tools are missing, report a
   failed MCP connection. Do not substitute shell execution and claim setup passed.
   An unconfigured-vault tool error means the connection works but needs a binding.
2. Reuse the reported vault unless the user requests a switch. If unconfigured, ask
   for an existing vault or a location for an explicitly requested new one. Never
   infer a vault from cwd or plugin location, or create another vault to repair access.
3. Call `orbit_setup` with the selected absolute path. Use `create: true` only when
   creating a new vault was requested. On denied access follow the host procedure;
   preserve the selection and retry after a supported permission grant.
4. Run `orbit_doctor`. Read its reported rules file with `orbit_read`. Preserve
   identity, rules, unknown config fields and user content. Fresh vaults use format 2
   and the standard folders with schema notes. Existing vaults are not reorganized;
   use [migrate](../orbit-migrate/SKILL.md) when the user requests their upgrade.
5. Perform the [setup write check](../../references/setup.md) through `orbit_apply`,
   `orbit_search` and `orbit_read`. Update the existing labeled record with its current
   hash. A diagnostic or no-op write is insufficient.
6. Report the vault and checks actually passed. A fresh conversation must recall the
   receipt without rebinding; test each other app separately before claiming support.

Upgrades preserve the binding outside the plugin. Mounted environments may require
another config containing their actual accessible path to the same vault. Matching
path strings, a successful installation, and shell tests are not native-host acceptance.
