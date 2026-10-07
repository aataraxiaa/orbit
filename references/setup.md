# Set up Orbit through MCP

The plugin provides local MCP tools backed by the existing Python storage engine.
Python 3.10+ must be installed. If `python3` is older, the launcher checks PATH
and standard Homebrew bin directories for a supported interpreter. The plugin and desktop
extension do not install Python. A shell's PATH may differ from the app's launch environment.
Knowledge, persistent config and caches stay outside the installed plugin.

## Check the connection first

Discover `orbit_doctor`, `orbit_setup`, `orbit_search`, `orbit_read` and `orbit_apply`.
Call `orbit_doctor`. An unconfigured-vault error proves the tool is reachable and setup
is needed. Missing tools or a startup error mean the connection failed. Report that
failure and the host's actual diagnostic. Do not run the Python helper as a fallback
and call that a successful MCP connection. Do not create another vault to repair access.

## Installation routes

For ChatGPT/Codex desktop, use its Plugins directory and add the GitHub marketplace
`aataraxiaa/orbit` where the app supports repository marketplaces. Install Orbit from
that source. For a local development marketplace, add `dist/marketplace`, restart the
app if required to refresh sources, and install `orbit@orbit-local`.

For Cowork in Claude Desktop, use **Customize > Plugins > Add > Add marketplace**,
add `aataraxiaa/orbit`, and install Orbit. Use the path accessible to the MCP server,
normally the Mac absolute path for local Cowork. Its MCP process is separate from
Cowork's shell sandbox; do not infer the vault path from that sandbox. Use host
permission controls if the MCP tool reports denied access.

For Claude Desktop Chat, `dist/orbit.mcpb` is the separately packaged desktop extension.
Open the file using Claude's desktop extension installation controls. It uses the same
engine and default binding. This candidate route requires native-app acceptance;
a successful package build does not prove the Chat connection. It is not a marketplace
publication or automatic extension update channel.

Ordinary ChatGPT chat is a separate surface. This local plugin does not provide a
remote connector or host the user's vault. Do not claim it works in ordinary ChatGPT
chat based on Codex/Work tools being available.

## Select the vault once

Reuse the vault reported by `orbit_doctor` unless the user requests a switch. If no
binding exists, ask for an existing vault or an explicitly requested new location.
Call `orbit_setup` with the absolute `path`; set `create: true` only for a new vault
requested by the user. Setup preserves identity, rules, existing notes and unknown
config fields. Rerun setup after an interrupted binding attempt rather than deleting
markers or resetting rules.

The default config is `~/.config/orbit/config.json`, with the existing legacy
`~/.config/second-brain/config.json` used when no new config exists. `ORBIT_CONFIG`
selects another config file at MCP process launch. `ORBIT_VAULT` overrides that binding;
legacy `SECOND_BRAIN_*` variables remain fallbacks. The optional `vault` tool argument
is an explicit per-call override. Never infer a vault from the plugin or working directory.

Local agents sharing the same home directory normally share the config. If a particular
MCP runtime uses mounted paths or runs remotely, it may need its own binding to the
same accessible vault folder. A path
string alone does not prove shared files or persistence. Do not assume GUI processes
inherit shell exports. Keep `ORBIT_CACHE` outside the synced vault.

## Permission failures

Report the exact path and diagnostic from the MCP tool. Grant access through the
host's supported controls to the selected vault and effective config parent, including
atomic replacement of config files. Do not disable sandboxing, grant all-home access,
change settings silently, or route around a denied path with another tool. Preserve
the selected path so setup resumes without asking the user to choose again.

## Verify the current conversation

Run `orbit_doctor`, then read the reported rules file (`ORBIT.md` or legacy
`SECOND_BRAIN.md`) with `orbit_read`. Search for an existing setup-check note and read
all of it before updating. Follow the vault's conventions; keep one labeled setup-check
record across agents and preserve its identity, prior receipts and user prose.

Use `orbit_apply` to write a new receipt containing this host's name, a computed timestamp
and a unique phrase. Include the exact SHA-256 from read for an existing note, or null
for a new note. The note needs string frontmatter `id`, `title`, `type`, `summary`.
A no-op apply does not prove write access. On conflict, reread and merge.

Search for the unique phrase with `orbit_search` and read it back with `orbit_read`.
Run `orbit_doctor` again for pending operations or integrity issues. Report only checks
actually passed in this conversation, using the verified paths from tool results.

A fresh conversation must recall that receipt without setup again. Each other target
app must read the same receipt, write its own addition, and preserve it after restart.
These native checks are separate from subprocess tests or a probe's transport checks.
