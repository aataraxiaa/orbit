# Native Swift runtime transition

Orbit 0.7.0-beta.1 is a native Swift runtime replacement. It keeps disk format 3 and the existing revision protocol. The package version does not identify a new disk format.

For an existing format-3 Orbit, the migration tool's default plan verifies compatibility without changing content. Report its actual source release, format and findings. Do not rewrite the marker merely because the package language or version changed. For formats 1 and 2, retain the existing explicitly authorized legacy routes and their previews, backup journals, resume and rollback behavior.

Installing or testing a native plugin does not authorize migrating a personal Orbit. Verify native candidates only with disposable folders and isolated registry/cache/state. The user authorized this prerelease for in-app testing before native-host and physical cross-device acceptance. Python remains available only as a development reference and the previous 0.6.0 release provides the runtime rollback option. A package build or direct subprocess call is mechanical evidence only.

Before any authorized transition, preserve the complete folder, including Markdown, original assets, `.orbit/commits`, `.orbit/observations`, integration records and migration backups. Keep device-local registry and recovery state separately. Accepted revisions remain immutable. Roll back a runtime only after proving the previous reader can consume the new snapshots. Never delete new history or restore an old Markdown-only backup over it. Restoring content in format 3 is a new reviewed revision.

An interrupted or repeated format-3 compatibility check is safe to rerun. An interrupted format migration must use its recorded operation; do not start another migration around it. Changed user bytes or later accepted history can make rollback unsafe, and the tool must refuse rather than overwrite them.
