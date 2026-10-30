# Native Swift runtime transition

The development OrbitCore package is a runtime replacement. It keeps disk format 3 and the existing revision protocol. Package version `0.7.0-dev` does not identify a new disk format or a published release.

For an existing format-3 Orbit, the migration tool's default plan verifies compatibility without changing content. Report its actual source release, format and findings. Do not rewrite the marker merely because the package language or version changed. For formats 1 and 2, retain the existing explicitly authorized legacy routes and their previews, backup journals, resume and rollback behavior.

Installing or testing a native plugin does not authorize migrating a personal Orbit. Verify native candidates only with disposable folders and isolated registry/cache/state. Keep the shipping Python runtime until differential fixtures, native plugin acceptance and cross-device acceptance pass. A package build or direct subprocess call is mechanical evidence only.

Before any authorized transition, preserve the complete folder, including Markdown, original assets, `.orbit/commits`, `.orbit/observations`, integration records and migration backups. Keep device-local registry and recovery state separately. Accepted revisions remain immutable. Roll back a runtime only after proving the previous reader can consume the new snapshots. Never delete new history or restore an old Markdown-only backup over it. Restoring content in format 3 is a new reviewed revision.

An interrupted or repeated format-3 compatibility check is safe to rerun. An interrupted format migration must use its recorded operation; do not start another migration around it. Changed user bytes or later accepted history can make rollback unsafe, and the tool must refuse rather than overwrite them.
