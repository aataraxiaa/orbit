# Mixed Python and Swift replicas

Build `orbit-mcp` through MobileBuildMCP, then run this with Python 3.10 or later:

```sh
python3 scripts/mixed_replica_compatibility.py \
  --swift /absolute/path/to/prebuilt/orbit-mcp \
  --output work/mixed-replica-results.json
```

The runner interprets the language-neutral requests and delivery steps in `tests/fixtures/compatibility/replica-transport.json`. Each scenario starts from the same fixed-identity format-3 bytes. A Python/Python reference runs beside a mixed pair, with Swift on each side in turn. A third replica supplies a late branch. All folders, registrations, caches and recovery locations are disposable and isolated.

Every checkpoint compares returned values and SHA-256 hashes of every stored file. History checks assert expected revision counts as well as equivalent content. The report records the native executable hash and result/storage manifest hashes. The runner refuses fixture paths outside its disposable folders and checks that local locks, checkout state and SQLite files do not appear in synced data.

Coverage includes offline changes to different notes, same-note resolution followed by a late branch, missing parents, Markdown before its envelope, external observations and adoption, path collisions and retained losing identities, asset dependencies blocking a whole batch, invalid history, exact retries and fresh processes.

The projection fault uses actual filesystem permissions. An accepted envelope reaches a replica while its Markdown is still historical. The destination folder becomes read-only. Retrying the exact accepted request must preserve a committed local receipt with `verified=false` and interrupted projection. The runner kills and restarts that MCP process, restores access, and retries the same UUID. Projection must recover without an additional revision. Only recognized platform-specific permission error wording is classified for comparison; all other receipt fields and durable bytes compare exactly.

A separate test holds Python's local OS lock while issuing a request to the native process against the same folder and state location. The native request must wait until the Python lock is released. This proves the overlapping local writers share the lock identity.

These are filesystem transport and executable tests. They do not verify native desktop plugin installation, host conversations, iCloud delivery, security-scoped bookmarks, or physical-device behavior. The committed result file identifies the tested binary; rerun after rebuilding a changed candidate.
