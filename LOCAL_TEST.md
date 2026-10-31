# Install and test Orbit

Orbit 0.7.0-beta.2 uses the native universal Swift executable on macOS 13 or later. Download the [Swift prerelease packages](https://github.com/aataraxiaa/orbit/releases/tag/v0.7.0-beta.2) or update Orbit through the existing marketplace. Neither the plugin nor MCPB requires Python.

Python 3.10+ is a development dependency for the reference regression suite, fixture generators and package assembly. Python engine files remain in the source checkout and are excluded from production packages. This prerelease is authorized for in-app testing before formal native-host/iCloud/model acceptance; do not report those checks as passed.

## Install and verify in the apps

Use the app's marketplace controls to add `aataraxiaa/orbit` and install Orbit.
For Cowork, use **Customize > Plugins > Add > Add marketplace**. For ChatGPT/Codex
use the Plugins directory. These repository installs can update from GitHub.
For a local candidate, use the generated `dist/marketplace` source, named `orbit-local`.
Restart the app if needed to refresh its marketplace picker.

Ask to set up Orbit in a fresh conversation. The agent must discover `orbit_list`, `orbit_doctor`,
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
Installed 0.5.0 MCP setup, save/search/read, registration rename and format compatibility
checks passed in one Codex desktop conversation on 2026-10-24. Fresh-conversation,
Claude and cross-app acceptance remain pending. See [setup](references/setup.md).

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
The smoke script isolates these values automatically. For format-3 tests also set
`ORBIT_STATE` to a disposable machine-local path outside the folder; it is separate
from the rebuildable search cache.

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

Codex reads `.codex.mcp.json` with `/usr/bin/env`, `cwd: "."` and the plugin-relative `./bin/orbit-mcp` argument.
Claude reads `.mcp.json` with `${CLAUDE_PLUGIN_ROOT}`. The MCPB uses `${__dirname}`.
Do not reuse the Claude placeholder in Codex: it previously reached the launcher literally
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

## Verify named Orbits in 0.5.0

Use isolated config/cache and disposable Personal and Work paths. Register both and
list them. Save different content to the same relative note path in concurrent chats.
Verify every receipt names its target, then search/read each after a fresh process.
An omitted selector with two entries, an unknown name, an unregistered path, or a
replaced vault ID must fail before cache or vault writes. Registering initialized vaults
must preserve bootstrap files byte-for-byte. Check concurrent registration and safe reruns after an interrupted config write. Package tests exercise extracted manifests.

Native acceptance additionally requires two simultaneous conversations, one-off
overrides, deliberate conversation switches, labelled combined recall, cross-app
save/read and fresh-chat selection. Unit and MCP subprocess checks do not prove these.

For setup and rename, link a populated ordinary folder without Obsidian, then rename
its initial Orbit to Work. Verify all existing file bytes and identity remain unchanged.
Save with Work and read it back from a fresh process. The old name and a conflicting
name must fail without writing. Exercise rename concurrently with registration.
In each native host, check explicit request destinations override a conversation's
choice, one-off saves do not switch it, and confirmations use returned target receipts.
Quoted mentions of another Orbit must not change the destination.


## Verify the 0.6.0 revision prerelease

Build/package checks and a simulated transport are
mechanical evidence; native two-Mac iCloud and cross-app behavior remain unverified.
Use disposable folders and separate config, cache and state paths for each replica.
Copy the complete initialized folder, including .orbit/commits and .orbit/observations,
so both replicas share one vault identity and initial history. Do not register the two
copies together in one registry; use separate isolated registries/processes.

1. Save different notes independently while disconnected. Deliver immutable operations
   and Markdown in both orders, including duplicates. Call orbit_sync reconcile and
   verify both notes through read/search after all dependencies arrive.
2. Edit the same note on both replicas. Deliver both histories. Status must expose
   identical competing heads; ordinary read/search must not silently pick a winner.
   Read history, preserve both claims, and apply reviewed Markdown using exact current
   expected_heads, observations and physical content hash. Deliver that operation and
   verify convergence. Late unseen branches must reopen the conflict.
3. Give apply a request_id canonical UUID. Retry the identical plan after acceptance,
   including stale before hashes: expect one logical operation. Reuse with changed
   content must refuse. Repeat after a process kill between acceptance and checkout.
4. Deliver Markdown before its operation. Reconcile must preserve unexplained bytes as
   observations rather than inventing ancestry. Later history may explain them. For
   actual editor changes, explicitly adopt the observation through apply; do not claim
   protection for edits overwritten before Orbit observed them.
5. Delay parents or source assets, corrupt an envelope and create a path collision.
   Pending/invalid status must remain visible and unsafe projection must refuse.
6. Delete only the local SQLite cache, start a fresh process/conversation and verify
   retained revisions and conflicts remain. Do not delete durable history or ORBIT_STATE
   while a process is using it. Local save never proves upload or peer acknowledgment.
7. On a disposable format-2 copy, preview migration to 0.6.0, apply, compare every
   original note/asset byte and repeat the plan. Interrupt seed/marker publication,
   resume and rollback separately. Later content edits or history additions must cause
   recovery refusal. A format-1 fixture first follows explicit target 0.5.0 to format 2.

Run the full unit suite, smoke and package commands above after changes. Include the
replication, transport and migration test files present in this checkout. Record exact
artifact hashes for native testing. The physical two-Mac matrix must repeat these
scenarios through real installed plugin processes, then confirm cross-app and fresh-chat
readback; deterministic file copying cannot establish iCloud transport behavior.

The synthetic retrieval evaluation creates an existing format-1 corpus before setup. Its report labels `data_format: 1`; it measures retrieval rather than replication performance. Cross-device behavior is covered by the replica and MCP suites.

## Swift compatibility checks

Build and test the root Swift package through MobileBuildMCP. Run `scripts/swift_compatibility.py --swift <built-orbit-mcp> --output <report.json>` using supported Python. The runner creates all folders/config/cache/state in a disposable temporary directory and compares responses plus stored file hashes. Frozen fixtures also cover exact legacy migration plans, seed histories, schema conflicts and interrupted recovery. These are mechanical checks. Follow [native transition acceptance](docs/swift-migration/transition.md) for the remaining in-app checks and rollback guidance.
