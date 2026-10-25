# Format 2 to 3 in Orbit 0.6.0

Upgrade every computer and desktop plugin using the folder before enabling format 3.
Receiving the format-3 marker causes 0.5.0 writers to refuse. This does not fence an
offline old writer that has not received the marker. Pause other writers during migration.

Call orbit_migrate with action plan and target_version 0.6.0 on the explicitly selected
Orbit. The preview is read-only and includes a plan_id and warnings. Apply that exact
plan only within authorization to migrate this Orbit. Changed files invalidate the plan.

The migration seeds immutable revision evidence from exact existing Markdown and
integration JSON, preserves sources and all note bytes, then updates the format marker.
It does not reorganize folders, rewrite metadata, or resolve existing contradictory claims.
The recovery journal retains original marker/content snapshots and baseline hashes.

After apply, read the returned operation and backup path. Repeat plan: it must return
unchanged with compatible true. Inspect orbit_sync status, rebuild the local index and
read representative notes, including notes with custom metadata and source links.
A local receipt proves local persistence, not delivery to another computer.

For an interrupted migration, use resume with the returned operation ID. For rollback,
use rollback with that ID. Recovery refuses subsequent content edits, additional history,
or modified history; preserve those changes and investigate rather than deleting them.
A rolled-back operation cannot resume forward; make a new preview.

Format 1 requires two explicit stages: target_version 0.5.0 using the format-1-to-2
reference, followed by a new preview targeting 0.6.0. Keep both recovery receipts.
Rollback the newest stage first. Unsupported future versions refuse rather than downgrade.

For existing format 3, plan 0.6.0 checks history compatibility without changing files.
Pending or invalid immutable history prevents a compatibility success; deliver dependencies
or repair retained evidence before retrying. Mechanical migration tests do not establish
native cross-computer, iCloud, or cross-app acceptance.
