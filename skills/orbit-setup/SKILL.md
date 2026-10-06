---
name: orbit-setup
description: Set up Orbit, choose or create an Obsidian vault, connect this agent to it, switch vaults, or diagnose access from a fresh conversation. Use only for explicit setup or access repair.
---

# Set up Orbit

Connect this host to the user's shared vault and prove it can save and retrieve a note.
An existing binding identifies the vault; it does not prove this host has access.

1. Read [host setup](../../references/setup.md) and [tools](../../references/tools.md).
2. Locate the installed helper and determine where this host's tools execute. Check
   Python support, current permission policy, `ORBIT_CONFIG`, and
   `ORBIT_VAULT`. Read the effective config if accessible. Distinguish a denied
   read from a missing binding. Never infer a vault from the repo or plugin location.
3. Reuse the selected vault unless the user requests a switch. If no selection exists,
   ask for an existing vault or a location for a new one. A second agent on the same
   machine normally shares the binding; it still needs its own access and write check.
4. Check this host's access before setup writes using the applicable
   [host procedure](../../references/setup.md). If access is blocked, tell the user
   exactly which paths need access and give the supported commands or settings edit
   with their actual paths filled in. Do not silently change host permission settings.
   Wait for the user to grant access, then retry and verify. A fresh chat alone does
   not grant access. Preserve the selected paths so setup can resume without asking again.
5. Run setup with the selected path. Use `--create` only for an explicitly requested
   new vault. Rerun setup after an interrupted attempt or from another agent; preserve
   the existing marker, rules, notes, and unknown config fields. Read the rules file reported by doctor, `ORBIT.md` or legacy `SECOND_BRAIN.md`,
   and follow its conventions. Change existing rules only when the user requests it.
6. Run doctor, then perform the [setup write check](../../references/setup.md)
   through this host's tools on every setup, including an already-bound vault. Update
   the existing setup-check note with its read hash; do not create one note per agent.
   Search and read back the new receipt. Doctor alone does not prove sandbox write access.
7. Report the vault, config location, persistent access changes, and checks actually
   passed in this host. Link the binding and setup-check note using their verified
   absolute paths from this run; never use placeholder or guessed links. Identify any
   restart or user action still required. Request a fresh-chat recall check separately;
   do not claim another host passed until tested.

Plugin upgrades preserve the binding. A remote or mounted environment may need its own
config containing the path its tools can access. Never claim local access from a matching
path string or assume GUI applications inherit shell environment variables.
