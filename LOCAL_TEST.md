# Install and test Orbit

Orbit requires Python 3.11 or later and a host that can execute local scripts and access your vault.
SQLite FTS5 support enables indexed search. No third-party Python dependencies are required.

## Install from GitHub

In Codex with native plugin support:

```sh
codex plugin marketplace add aataraxiaa/orbit
codex plugin add orbit@orbit
```

Inside Claude Code:

```text
/plugin marketplace add aataraxiaa/orbit
/plugin install orbit@orbit
```

Start a new conversation and ask to set up Orbit. Choose an existing vault or request a disposable
one. Grant access to the selected vault and effective config directory using your host's controls.
Repeat setup and a write/read check in each host. Installation alone does not verify filesystem access.

For Claude Desktop or Cowork, download `orbit-plugin.zip` from GitHub Releases and use the
custom-plugin upload control if supported. Script execution and vault access must be verified there.
These app workflows have not passed runtime acceptance.

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

The build creates `dist/orbit-plugin.zip` and `dist/orbit-project.zip`. The project archive contains
source, tests, and a built local marketplace. The plugin archive contains runtime files only.
Reinstall or reload after rebuilding. Vault bindings live outside the plugin.

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
6. Inspect `index`, `catalog`, `relations`, `integration`, and `maintain` using the packaged helper.

Use `python3 scripts/eval.py --output /absolute/report.json` for synthetic helper retrieval evaluation.
Fixtures ship in the project archive. Real host behavior is a separate check.
See [acceptance](references/acceptance.md) and [tool contracts](references/tools.md).
