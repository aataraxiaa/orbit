# Recover a migration

Call doctor and use the recorded migration operation ID. Ordinary writes are
blocked while a migration is prepared. Do not use the ordinary save-recovery tool
for migration journals.

Use `orbit_migrate` with `action: "resume"` to complete the recorded operation,
or `action: "rollback"` when the user requests restoration. Supply `operation`.
Recovery checks every affected file before changing any of them. If a user edited
one, preserve that edit and report the conflicting path; do not force recovery.

A process crash can leave a writer lock. Establish that no process is writing
before arranging removal through a supported host file operation. Never remove
a lock merely because it exists. Retry recovery after resolving the lock.

Retain the backup journal after recovery. Rebuild SQLite, run doctor, and verify
the recovered note paths and content. Report whether the operation completed or
rolled back, and any remaining conflicts or stale integration evidence.
