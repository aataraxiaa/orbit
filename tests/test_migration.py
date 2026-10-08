import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import migration
import orbit


def note(identity, kind, title, body='', **fields):
    meta = dict(id=identity, type=kind, title=title, **fields)
    return '\ufeff---\r\n' + ''.join(k + ': ' + json.dumps(v) + '\r\n' for k, v in meta.items()) + 'custom:\r\n  untouched: yes\r\n---\r\n# ' + title + '\r\n' + body


class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'vault'
        self.root.mkdir()
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': self.temp.name + '/config', 'ORBIT_CACHE': self.temp.name + '/cache'})
        self.env.start()
        self.put('.orbit/vault.json', '{"schema": 1, "id": "stable", "custom": 4}\n')
        self.put('Old/Atlas.md', note('atlas', 'project', 'Atlas', '[decision](Decision.md#why)\n![asset](../Sources/assets/image.bin)\n'))
        self.put('Old/Decision.md', note('decision', 'decision', 'Decision', '[[Old/Atlas#Goal|Atlas]]\n`[[Old/Atlas]]`\n```md\n[[Old/Atlas]]\n```\n', project='atlas'))
        self.put('manual.md', '[project](Old/Atlas.md "title")\n[ref]: Old/Atlas.md#Goal\n')
        self.put('Sources/assets/image.bin', 'original\r\n')

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def put(self, path, value):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value.encode())

    def snapshot(self):
        return {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob('*') if p.is_file() and '/migrations/' not in p.as_posix()}

    def test_preview_apply_noop_and_exact_rollback(self):
        before = self.snapshot()
        preview = migration.migrate(self.root)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(preview['source_version'], 'unknown')
        result = migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        self.assertTrue(result['verified'])
        project = (self.root / 'Projects/Atlas/Overview.md').read_bytes().decode()
        self.assertIn('Decisions/Decision.md#why', project)
        self.assertIn('../../Sources/assets/image.bin', project)
        self.assertIn('custom:\r\n  untouched: yes\r\n', project)
        self.assertTrue(project.startswith('\ufeff'))
        decision = (self.root / 'Projects/Atlas/Decisions/Decision.md').read_text()
        self.assertIn('[[Projects/Atlas/Overview#Goal|Atlas]]', decision)
        self.assertIn('`[[Old/Atlas]]`', decision)
        self.assertIn('```md\n[[Old/Atlas]]\n```', decision)
        self.assertEqual(migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])['status'], 'unchanged')
        migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(before, self.snapshot())
        migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(before, self.snapshot())

    def test_stale_preview_and_collision_are_read_only(self):
        preview = migration.migrate(self.root)
        self.put('new-file.txt', 'external change')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'stale'):
            migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        self.assertEqual(before, self.snapshot())
        self.put('Projects/Atlas/Overview.md', 'user file')
        with self.assertRaisesRegex(orbit.OrbitError, 'already exists'):
            migration.migrate(self.root)

    def interrupt(self):
        preview = migration.migrate(self.root)
        atomic = orbit.atomic
        count = 0
        def fail(path, data):
            nonlocal count
            count += 1
            if count == 4:
                raise OSError('simulated interruption')
            atomic(path, data)
        with patch.object(orbit, 'atomic', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'simulated'):
                migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        return migration.status(self.root)['pending'][0]

    def test_interrupted_resume_blocks_writes(self):
        op = self.interrupt()
        with self.assertRaisesRegex(orbit.OrbitError, 'pending migration'):
            migration.ensure_writable(self.root)
        self.assertEqual(migration.migrate(self.root, 'resume', operation=op)['status'], 'committed')
        self.assertEqual(migration.status(self.root)['data_format'], 2)
        migration.ensure_writable(self.root)

    def test_interrupted_rollback_exact_backup(self):
        before = self.snapshot()
        op = self.interrupt()
        migration.migrate(self.root, 'rollback', operation=op)
        self.assertEqual(before, self.snapshot())

    def test_recovery_preflights_all_paths_before_mutation(self):
        op = self.interrupt()
        self.put('manual.md', 'subsequent user edit')
        before = self.snapshot()
        for action in ('resume', 'rollback'):
            with self.assertRaisesRegex(orbit.OrbitError, 'conflict'):
                migration.migrate(self.root, action, operation=op)
            self.assertEqual(before, self.snapshot())

    def test_unknown_version_and_ambiguous_project_refuse(self):
        with self.assertRaisesRegex(orbit.OrbitError, 'Unsupported migration target'):
            migration.migrate(self.root, target_version='0.3.0')
        self.put('.orbit/vault.json', '{"schema":1,"data_format":3,"id":"stable"}')
        with self.assertRaisesRegex(orbit.OrbitError, 'Unsupported vault'):
            migration.migrate(self.root)
        self.put('.orbit/vault.json', '{"schema":1,"id":"stable"}')
        self.put('Other.md', note('other', 'project', 'Atlas'))
        self.put('Old/Decision.md', note('decision', 'decision', 'Decision', project='Atlas'))
        with self.assertRaisesRegex(orbit.OrbitError, 'unambiguous'):
            migration.migrate(self.root)

    def test_unsupported_links_and_metadata_links_refuse(self):
        for text in ('[nested](thing(foo).md)', '---\ncustom: "[[Old/Atlas]]"\n---\nbody'):
            self.put('manual.md', text)
            before = self.snapshot()
            with self.assertRaises(orbit.OrbitError):
                migration.migrate(self.root)
            self.assertEqual(before, self.snapshot())

    def test_every_write_boundary_recovers_forward_and_backward(self):
        original = self.snapshot()
        preview, writes = migration._prepare(self.root)
        for rollback in (False, True):
            for fail_at in range(2, len(writes) + 3):
                with self.subTest(rollback=rollback, fail_at=fail_at):
                    for p in self.root.rglob('*'):
                        if p.is_file():
                            p.unlink()
                    for path, data in original.items():
                        target = self.root / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(data)
                    atomic = orbit.atomic
                    unlink = Path.unlink
                    calls = 0
                    def fail(path, data):
                        nonlocal calls
                        calls += 1
                        if calls == fail_at:
                            raise OSError('interruption')
                        atomic(path, data)
                    def fail_delete(path, *args, **kwargs):
                        nonlocal calls
                        if path.name != 'write.lock':
                            calls += 1
                            if calls == fail_at:
                                raise OSError('interruption')
                        return unlink(path, *args, **kwargs)
                    with patch.object(orbit, 'atomic', side_effect=fail), patch.object(Path, 'unlink', fail_delete):
                        with self.assertRaises(OSError):
                            migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
                    op = migration.status(self.root)['pending'][0]
                    migration.migrate(self.root, 'rollback' if rollback else 'resume', operation=op)
                    if rollback:
                        self.assertEqual(original, self.snapshot())
                    else:
                        self.assertEqual(migration.status(self.root)['data_format'], 2)
                        self.assertTrue((self.root / 'Projects/Atlas/Overview.md').is_file())

    def test_interrupted_committed_rollback_stays_pending_and_resume_rolls_back(self):
        before = self.snapshot()
        preview = migration.migrate(self.root)
        result = migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        atomic = orbit.atomic
        calls = 0
        def fail(path, data):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError('rollback interruption')
            atomic(path, data)
        with patch.object(orbit, 'atomic', side_effect=fail):
            with self.assertRaises(OSError):
                migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(migration.status(self.root)['pending'], [result['operation']])
        with self.assertRaises(orbit.OrbitError):
            migration.ensure_writable(self.root)
        self.assertEqual(migration.migrate(self.root, 'resume', operation=result['operation'])['status'], 'rolled-back')
        self.assertEqual(before, self.snapshot())

    def test_verification_rereads_final_bytes(self):
        preview = migration.migrate(self.root)
        atomic = orbit.atomic
        def external_edit(path, data):
            atomic(path, data)
            if path.name == 'vault.json':
                self.put('Projects/Atlas/Overview.md', 'external edit during migration')
        with patch.object(orbit, 'atomic', side_effect=external_edit):
            with self.assertRaisesRegex(orbit.OrbitError, 'verification conflict'):
                migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        self.assertTrue(migration.status(self.root)['pending'])

    def test_extensionless_encoded_and_reference_links(self):
        self.put('manual.md', '[project](Old/Atlas#Goal)\n[encoded](Old/%41tlas.md?mode=1#Goal)\n[ref]: <Old/Atlas.md> "Title"\n')
        preview = migration.migrate(self.root)
        migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        text = (self.root / 'manual.md').read_text()
        self.assertIn('(Projects/Atlas/Overview#Goal)', text)
        self.assertIn('(Projects/Atlas/Overview.md?mode=1#Goal)', text)
        self.assertIn('[ref]: <Projects/Atlas/Overview.md> "Title"', text)

    def test_current_format_does_not_reclassify_projectless_sessions(self):
        preview = migration.migrate(self.root)
        migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        self.put('Knowledge/session.md', note('session', 'session', 'Session'))
        result = migration.migrate(self.root)
        self.assertEqual(result['status'], 'unchanged')
        self.assertTrue(result['schema_warnings'])

    def test_nested_markdown_label_refuses_before_moving_target(self):
        self.put('manual.md', '[see [Atlas]](Old/Atlas.md)\n')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'Unsupported Markdown'):
            migration.migrate(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_future_source_release_refuses_writes_and_downgrade(self):
        self.put('.orbit/vault.json', '{"schema":1,"id":"stable","data_format":1,"orbit_version":"9.0.0"}')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'newer Orbit'):
            migration.ensure_writable(self.root)
        with self.assertRaisesRegex(orbit.OrbitError, 'downgrade'):
            migration.migrate(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_moved_custom_schema_does_not_create_duplicate_default(self):
        import structure
        template = (structure.TEMPLATES / 'Project.md').read_text().replace('orbit-schema-project-v1', 'custom-project-schema')
        self.put('Old/Custom.md', template)
        preview = migration.migrate(self.root)
        migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        self.assertTrue((self.root / 'Schemas/Custom.md').exists())
        self.assertFalse((self.root / 'Schemas/Project.md').exists())
        self.assertFalse([w for w in structure.check(self.root)['warnings'] if w['severity'] == 'error'])
        self.assertEqual(migration.migrate(self.root)['status'], 'unchanged')

    def test_integration_receipt_is_historical_not_forged(self):
        evidence = {'path': 'Old/Atlas.md', 'sha256': orbit.digest((self.root / 'Old/Atlas.md').read_bytes())}
        record = {'stage': 'verified', 'notes': [evidence], 'extraction': [], 'errors': [], 'verification': [{'historical': True}]}
        self.put('.orbit/integrations/source.json', json.dumps(record))
        preview = migration.migrate(self.root)
        migration.migrate(self.root, 'apply', plan_id=preview['plan_id'])
        after = json.loads((self.root / '.orbit/integrations/source.json').read_text())
        self.assertEqual(after['notes'], [evidence])
        self.assertEqual(after['verification'], record['verification'])
        self.assertTrue(after['migration']['verification_stale'])
        self.assertTrue(after['errors'])


if __name__ == '__main__':
    unittest.main()
