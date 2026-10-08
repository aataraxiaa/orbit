# Install and test Orbit

Orbit requires an installed Python 3.10+ and access to
the selected vault. SQLite FTS5 enables indexed search. There are no third-party
Python dependencies. The plugin and MCPB do not install a Python runtime.

## Install and verify in the apps

Use the app's marketplace controls to add `aataraxiaa/orbit` and install Orbit.
For Cowork, use **Customize > Plugins > Add > Add marketplace**. For ChatGPT/Codex
use the Plugins directory. These repository installs can update from GitHub.
For a local candidate, use the generated `dist/marketplace` source, named `orbit-local`.
Restart the app if needed to refresh its marketplace picker.

Ask to set up Orbit in a fresh conversation. The agent must discover `orbit_doctor`,
`orbit_setup`, `orbit_apply`, `orbit_search` and `orbit_read`. Missing tools fail the
connection check. A shell fallback does not repair MCP or count as acceptance.
Choose the vault once; bind the path the actual MCP process can access, normally the
Mac absolute path for local Cowork. The MCP process is separate from Cowork's shell
sandbox. Only a genuinely mounted or remote MCP runtime needs its corresponding path.

`dist/orbit.mcpb` is a separate Claude Desktop Chat extension artifact. Install through
Claude's extension controls and verify its tools in Chat. MCPB bundles this engine
but does not publish it to an extension directory or establish automatic updates.
Ordinary ChatGPT chat has not been established by the local plugin route.

The disposable connection probe passed transport in Codex desktop and Cowork.
The production engine's native-app save/read and fresh-conversation acceptance remain
pending until recorded for this exact candidate. See [setup](references/setup.md).

## Develop locally

```sh
git clone https://github.com/aataraxiaa/orbit.git
cd orbit
python3 -m unittest discover -s tests -v
python3 scripts/smoke.py
python3 scripts/package.py
```

For Claude Code, load the checkout with `claude --plugin-dir /absolute/path/to/orbit`.
For local marketplace installation, add `/absolute/path/to/orbit/dist/marketplace` and install
`orbit@orbit-local`. The root GitHub marketplace is named `orbit`; the generated local marketplace
is named `orbit-local`.

The build creates `dist/orbit-plugin.zip`, `dist/orbit-project.zip`, and `dist/orbit.mcpb`. The project archive contains
source, tests, and a built local marketplace. The plugin archive contains runtime files only.
Reinstall or reload after rebuilding. Vault bindings live outside the plugin.

For Python compatibility changes, also run the full test suite and smoke script with
Python 3.10, the minimum supported interpreter. Use a real interpreter rather than
mocking its version. Cache corruption recovery and locked-cache preservation must pass.

## Verify product behavior

Use a disposable vault. Set `ORBIT_CONFIG` and `ORBIT_CACHE` to temporary paths outside that vault.
Unset both `ORBIT_VAULT` and the legacy `SECOND_BRAIN_VAULT` override when testing config selection.
The smoke script isolates these values automatically.

1. Discuss a staged rollout chosen because rollback must remain possible.
2. Ask "Save that to Orbit" and inspect the receipt and notes.
3. Start a new conversation and ask "Check Orbit: why aren't we launching all at once?"
4. Save an additional constraint that migrations must remain reversible. Check that existing
   knowledge is updated and useful links are added without duplicate project notes.
5. Edit a note externally and recall it again.
6. Inspect `index`, `catalog`, `relations`, `integration`, and `maintain` through the installed MCP tools.

Use `python3 scripts/eval.py --output /absolute/report.json` for synthetic helper retrieval evaluation.
Fixtures ship in the project archive. Real host behavior is a separate check.
See [acceptance](references/acceptance.md) and [tool contracts](references/tools.md).

## Manifest launch regression

Codex reads `.codex.mcp.json` with `cwd: "."` and a plugin-relative script argument.
Claude reads `.mcp.json` with `${CLAUDE_PLUGIN_ROOT}`. The MCPB uses `${__dirname}`.
Do not reuse the Claude placeholder in Codex: it previously reached Python literally
and failed before initialization. Package tests launch all extracted configurations,
but native host variable resolution remains a separate check.

## Verify migration and sessions

Use an isolated format-1 fixture containing a project, decision, session, source
asset, inbound/outbound links and unknown metadata. Call orbit_migrate with plan,
then apply using the returned plan_id. Verify moved paths, stable IDs, original
asset hashes and repaired links. Rebuild SQLite and recall with note_type=session.
A second plan must return unchanged. Test interrupted resume and rollback, and
confirm a subsequent human edit causes recovery refusal without additional writes.
The migration suite covers these mechanical cases. Separately test the packaged
plugin in each desktop host before claiming native migration acceptance.
