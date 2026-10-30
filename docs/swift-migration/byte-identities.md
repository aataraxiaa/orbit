# Byte-exact note identities

Python treats `café` and `café` as distinct stable identifiers. Swift's ordinary `String` equality treats those NFC and NFD forms as equal. Using `String` as a revision-entity dictionary key therefore combined accepted histories, rejected valid multi-note saves, and could classify a historical Orbit as invalid.

`OrbitByteString` supplies equality, hashing and ordering over the original UTF-8 bytes. Replication uses it for entity uniqueness, heads, write groups, legacy identity bindings, path claims, duplicate-ID checks, observation ownership, history filtering, and collision retirement. Snapshots and receipts continue to contain the original strings. Content/entity and ancestry comparisons use exact bytes. No on-disk migration or identifier normalization occurs.

Six regression tests fail with the previous implementation and pass with the fix. They cover a single operation containing both identifiers, genesis containing both, separate concurrent updates, separate external observations, collision resolution retaining the exact losing identity, and refusal to replace one stable identifier with its canonically equivalent spelling.

`replica-unicode-identities.json` also exercises the public MCP boundary against a Python/Python reference and mixed Python/Swift replicas, with Swift on each side. It begins with Python-created accepted history containing both identifiers. It asserts ready status, distinct histories, exact stored bytes, new identifiers in one save, separate editor observations, independent adoption and refusal of an identity swap. The old native binary failed on that historical seed. The rebuilt Release candidate passes all 55 checkpoints. The report records its SHA-256 at `mixed-unicode-results.json`.

Run the fixture against a previously built executable:

```sh
python3 scripts/mixed_replica_compatibility.py \
  --swift /absolute/path/to/prebuilt/orbit-mcp \
  --fixtures tests/fixtures/compatibility/replica-unicode-identities.json \
  --output work/mixed-unicode-results.json
```

These tests prove executable and file-contract behavior. They do not establish native desktop plugin or iCloud acceptance.
