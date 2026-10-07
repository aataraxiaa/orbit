# Set up a host

Orbit uses the host's existing execution and filesystem tools with Python 3.10+.
The plugin contains skills and scripts. Knowledge and configuration live outside it.

## Resolve the shared binding

Read `ORBIT_CONFIG` from the actual execution environment. Legacy `SECOND_BRAIN_CONFIG` remains a fallback. If unset, the config
is `~/.config/orbit/config.json`, or the existing `~/.config/second-brain/config.json` when the new config is absent. Expand the path using that environment's home
directory. `ORBIT_VAULT` overrides the config's `vault` value for helper commands;
resolve a conflicting override before verifying setup. Do not silently change vaults.

Codex and Claude Code on the same machine normally read the same config. Reuse that
selection, then grant access and verify a write in the current host. A config created by
Codex does not grant Claude permission. If the config cannot be read, obtain scoped
access before deciding it is missing. Only ask for a vault when no selection is available
or the user requests a switch.

For a remote host or Cowork mount, use the path its tools actually see. Keep a separate
config through `ORBIT_CONFIG` when local and remote paths differ. Configure the
override in that host's supported environment; a shell export need not reach a GUI app.
Never create a replacement vault merely because the selected one is inaccessible.

## Grant access before initialization

Resolve the absolute vault path and effective config parent first. Grant writes only to
those directories, including the parent needed for atomic config replacement. Keep the
engineering working directory unchanged. The plugin needs read and execution access;
it does not need to become a writable directory.

Inspect installed host support and effective policy before recommending settings edits. Preserve
all existing entries, deny rules, and active profile selection. Do not disable sandboxing,
grant all-home access, or add a blanket shell/Python allow rule. Use native approval for
a blocked helper invocation when the current policy permits it. Do not
retry a denial through another execution path to bypass the restriction.

Persistent settings and current-session permissions are separate. On a permission
failure, give the user the exact blocked paths and a concrete scoped settings edit or
supported launch command. Do not silently apply permission changes during setup.
Only edit host permission settings if the user explicitly asks you to apply that repair.
Otherwise wait for the user's grant, then verify the operation again. Record the selected
vault and config paths for resume. A fresh chat alone does not grant directory access.

## Connect Codex

Install from the generated `dist/marketplace` through the installed version's plugin
controls. The marketplace contains `.agents/plugins/marketplace.json`, which points to
`plugins/orbit`. Prefer native plugin installation.

Inspect the effective Codex configuration, including `CODEX_HOME` if set, and verify the
installed version supports the applicable settings. Use its configuration schema or
[official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

- With a named `default_permissions` profile, add the two absolute directory entries
  with value `"write"` to `permissions.<active-name>.filesystem`. Use the active name
  found in config. Preserve existing restrictions, including more specific deny entries.
- With legacy `sandbox_mode = "workspace-write"`, append the directories to
  `sandbox_workspace_write.writable_roots`, preserving and deduplicating existing roots.
- If policy or a managed configuration prevents the required access, name the conflicting
  restriction. Do not replace the profile or switch to unrestricted execution.

Use the current tool's native scoped permission or escalation request when supported
and allowed. Explain the exact command and directories it needs. If the policy is
`never`, do not issue an unavailable approval request. If a new session is required,
provide a supported app permission action verified in that app, or a CLI command after
checking `codex --help` supports its flags:

```sh
codex -C "/actual/code/directory" --sandbox workspace-write --add-dir "/selected/vault" --add-dir "/actual/config/parent"
```

Replace every placeholder with verified paths and preserve an explicit config override
in the new process. This command is a user-run scoped launch option when policy allows
it, not a way to escape a managed restriction. Resume setup in that session and verify
there. Do not claim that editing `config.toml` grants access to the running conversation.

## Connect Claude Code

For a development install, run `claude --plugin-dir /absolute/path/to/orbit`.
For a persistent install, add the generated `dist/marketplace` and install
`orbit@orbit-local` in user scope.

Verify the installed settings support against
[Claude Code settings](https://code.claude.com/docs/en/settings).
Merge the vault and config parent into `permissions.additionalDirectories` in the
user settings, normally `~/.claude/settings.json`. Preserve the rest of the JSON,
including existing additional directories and allow/deny rules. Avoid a project-only
grant when the user needs Orbit across projects.

Use Claude's native permission flow for the current session and approve only the needed
helper command. Directory access does not automatically approve shell execution. If the
session must restart, verify `claude --help` and provide the supported `--add-dir`
launch option with both resolved directories. Keep the actual code directory as cwd.
Continue using the shared Orbit config; do not reset it just because Codex
created it.

## Connect Cowork in Claude Desktop

Use **Customize > Plugins > Add > Add marketplace** to add `aataraxiaa/orbit`, then
install Orbit from that marketplace. Prefer the repository installation for updates.
Use the packaged ZIP only for a manual installation or local testing.
Connect the user's selected vault folder through Cowork's folder
access controls. Use the mounted path visible to its tools, which may differ from the
Mac path. Grant access to the effective config parent separately if required.

Locate `scripts/orbit.py` in the installed plugin and run it with `--help` using the
available Python interpreter. Python 3.10 is supported. Record the interpreter version
and any actual helper error before diagnosing runtime incompatibility. No vault binding
is needed for `--help`. The helper is a Python file, not a required `orbit` executable
on PATH. Missing plugin references or scripts are an installation problem, separate
from a missing vault selection.

The Chat tab and Cowork have different execution environments. Installing the skills
in Chat does not prove local vault access. If Chat cannot reach the vault, use Cowork
with the selected folder connected, or Claude Code. Do not describe the desktop app
alone as proof that scripts execute on the user's Mac.

Verify script execution and file access from the actual conversation. If the app cannot
execute helpers or grant access, identify that precise limitation and give a concrete
supported local-host route. Do not introduce a server or claim setup passed because
the plugin installed.

## Initialize or resume

After obtaining access, run the installed helper with the selected vault:

```sh
python3 "/absolute/plugin/scripts/orbit.py" setup "/selected/vault"
```

Add `--create` only when creating a new vault was requested. Setup preserves the existing
vault identity and rules, including legacy `.second-brain/vault.json` and `SECOND_BRAIN.md`, and unknown config fields. If a
previous attempt initialized the vault but failed to write config, rerun the same command
after repairing access. Do not remove the marker, reset rules, or delete notes to retry.

## Verify this host

Run doctor, then search for an existing Orbit setup-check record and read it fully.
Follow the rules file reported by doctor for its location. Use one record across agents. If none exists,
create a clearly labeled setup-check note with the required metadata from
[the note format](format.md). Do not repurpose unrelated user content.

On every setup, write a new receipt containing this host's name, a computed timestamp,
and a unique phrase. For an existing record, preserve its identity, metadata, prior
receipts, and user prose; use the exact hash returned by read in the apply plan. A no-op
apply is insufficient to demonstrate current write access. On a hash conflict, reread
and merge before retrying. Use [the helper workflow](tools.md) to apply the change,
search for its unique phrase, and read back the receipt. Run doctor again for unfinished
operations or integrity issues.

Report setup complete only after the config binding and real write/read check succeed
in the current host. Mechanical tests do not prove host permissions or LLM behavior.
Ask for recall in a fresh conversation to check persistence, and repeat setup in another
target host to prove that host's own access without creating a second orbit.
