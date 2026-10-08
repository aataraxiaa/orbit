# Format 2 compatibility

Call `orbit_migrate` with `action: "plan"` and `target_version: "0.4.1"`.
An unchanged result confirms the engine's format and schema compatibility checks.
Report any schema warnings separately. This does not prove semantic correctness
or mean that every manually added note follows the standard organization.

Do not move files or generate another backup for an unchanged vault. If the
compatibility check reports missing or malformed schemas, inspect the reported
files and repair only within the user's request. Never lower the recorded format
to force the older migration route.
