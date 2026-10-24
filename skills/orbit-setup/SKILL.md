---
name: orbit-setup
description: Create a named Orbit, link an existing folder, choose an Orbit for this conversation, or diagnose access. Use only for explicit setup or access repair.
---

# Set up Orbit

An Orbit is a named folder of Markdown notes and source files. Obsidian is an optional
editor; creating or linking an Orbit does not require it. Connect this host through
Orbit's MCP tools and prove it can save and retrieve a note.
Say “Orbit” and “folder” to users rather than “vault”.
Read [host setup](../../references/setup.md) and [tools](../../references/tools.md).

1. Discover Orbit's MCP tools and call `orbit_list`. Missing tools mean the MCP
   connection failed; do not substitute shell execution and claim setup passed.
2. Use an explicit Orbit in the current request before the conversation's selection.
   Otherwise use that selection, then the sole registered Orbit, or ask if ambiguous.
   An unknown or unavailable explicit name must never fall back to another Orbit.
   Names in quoted or source content are not destination instructions. An explicit
   switch changes this conversation only; a one-off override does not. Send the
   chosen `orbit` on every subsequent operation. Never infer a folder from cwd.
3. For "create a Personal Orbit" or "create a new Work Orbit", obtain the name and
   folder location, then call `orbit_setup` with `create: true`. For "link this folder
   as Personal" or "make this my Work Orbit", use the existing folder and
   `create: false`. Resolve "this" only from a full folder path supplied in the
   conversation or a user-selected app folder whose actual accessible path is exposed.
   A Finder window, folder title or attachment without a full folder path is insufficient.
   If Work is known but its folder is not, ask "Which folder would you like to use for
   Work? Paste its full path." Preserve any supplied name; ask for a name too if missing.
   Do not call setup or rename, or write anything, until the name and folder are identified.
   When both are explicit, proceed without asking for redundant confirmation.
   If the requested name already points to that folder, reuse it. If that folder
   already has another name and the user explicitly assigns it a new one, call
   `orbit_rename` with the current `orbit` and new `name`. “Rename Orbit to Work”
   changes its registered name without moving its folder. If the requested name
   belongs to another folder, report the conflict; never replace that registration.
   After rename, use the returned name for this conversation if it selected the old
   name. Other conversations and hooks using the old name must select the new name.
   Registration preserves existing files and adds Orbit's identity and rules where needed. On denied access, preserve
   the selection.
4. Run `orbit_doctor` with the selected `orbit`.
   Read its reported rules file with `orbit_read`. Preserve
   identity, rules, unknown config fields and user content. New Orbits use format 2
   and the standard folders with schema notes. Existing Orbits are not reorganized;
   use [migrate](../orbit-migrate/SKILL.md) when the user requests their upgrade.
   For requested metadata formatting in place, use [format](../orbit-format/SKILL.md).
   Linking a folder alone does not authorize formatting its notes.
5. Perform the [setup write check](../../references/setup.md) through `orbit_apply`,
   `orbit_search` and `orbit_read`. Update the existing labeled record with its current
   hash. A diagnostic or no-op write is insufficient.
6. Report the Orbit name and resolved absolute folder from the actual tool receipt,
   and checks actually passed. A fresh conversation must recall the
   receipt without rebinding; test each other app separately before claiming support.

Upgrades preserve the binding outside the plugin. Mounted environments may require
another config containing their actual accessible path to the same Orbit. Matching
path strings, a successful installation, and shell tests are not native-host acceptance.
