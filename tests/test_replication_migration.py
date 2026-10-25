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
import structure


class ReplicationMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'folder'
        self.root.mkdir()
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': self.temp.name + '/config',
                                          'ORBIT_CACHE': self.temp.name + '/cache',
                                          'ORBIT_STATE': self.temp.name + '/state'})
        self.env.start()
        self.put('.orbit/vault.json', json.dumps({'schema': 1, 'id': 'e72e3fac-7ccf-4b0f-814f-7ddde9350b9a',
                 'data_format': 2, 'orbit_version': '0.5.0', 'custom': {'preserve': True}}))
        for path, text in structure.bootstrap(self.root).items():
            self.put(path, text)
        self.put('Knowledge/Exact.md', '\ufeff---\r\nid: exact\r\ntitle: Exact\r\ntype: knowledge\r\nsummary: Original\r\ncustom:\r\n  nested: yes\r\n---\r\nBody\r\n')
        self.put('Sources/assets/original.bin', 'original\x00bytes')

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def put(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode())

    def snapshot(self):
        return {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob('*')
                if p.is_file() and '/migrations/' not in p.as_posix()}

    def apply(self):
        plan = migration.migrate(self.root)
        return migration.migrate(self.root, 'apply', plan_id=plan['plan_id'])

    def test_preview_seed_exact_bytes_repeat_and_rollback(self):
        before = self.snapshot()
        plan = migration.migrate(self.root)
        self.assertEqual(self.snapshot(), before)
        result = migration.migrate(self.root, 'apply', plan_id=plan['plan_id'])
        self.assertTrue(result['verified'])
        for path, data in before.items():
            if path != '.orbit/vault.json':
                self.assertEqual((self.root / path).read_bytes(), data)
        self.assertTrue(list((self.root / '.orbit/commits').rglob('*.json')))
        marker = json.loads((self.root / '.orbit/vault.json').read_bytes())
        self.assertEqual(marker['data_format'], 3)
        self.assertEqual(marker['custom'], {'preserve': True})
        self.assertEqual(migration.migrate(self.root)['status'], 'unchanged')
        migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(self.snapshot(), before)
        migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(self.snapshot(), before)

    def interrupt_after_seed(self):
        import replication
        seed = replication.seed
        def crash(*args, **kwargs):
            result = seed(*args, **kwargs)
            raise OSError('after seed')
        plan = migration.migrate(self.root)
        with patch.object(replication, 'seed', side_effect=crash):
            with self.assertRaisesRegex(OSError, 'after seed'):
                migration.migrate(self.root, 'apply', plan_id=plan['plan_id'])
        return migration.status(self.root)['pending'][0]

    def test_interrupted_seed_resume_and_repeated_resume(self):
        op = self.interrupt_after_seed()
        with self.assertRaisesRegex(orbit.OrbitError, 'pending migration'):
            migration.ensure_writable(self.root)
        self.assertEqual(migration.migrate(self.root, 'resume', operation=op)['status'], 'committed')
        snapshot = self.snapshot()
        migration.migrate(self.root, 'resume', operation=op)
        self.assertEqual(self.snapshot(), snapshot)

    def test_interrupted_seed_rollback_exact(self):
        before = self.snapshot()
        op = self.interrupt_after_seed()
        migration.migrate(self.root, 'rollback', operation=op)
        self.assertEqual(self.snapshot(), before)

    def test_rollback_refuses_external_content_and_extra_history(self):
        result = self.apply()
        original = (self.root / 'Knowledge/Exact.md').read_bytes()
        self.put('Knowledge/Exact.md', 'subsequent user edit')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'conflict'):
            migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(self.snapshot(), before)
        (self.root / 'Knowledge/Exact.md').write_bytes(original)
        self.put('.orbit/commits/extra.json', '{}')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'history'):
            migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertEqual(self.snapshot(), before)

    def test_stale_preview_and_future_format_refuse(self):
        plan = migration.migrate(self.root)
        self.put('new.txt', 'new bytes')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'stale'):
            migration.migrate(self.root, 'apply', plan_id=plan['plan_id'])
        self.assertEqual(self.snapshot(), before)
        marker = json.loads((self.root / '.orbit/vault.json').read_bytes())
        marker['data_format'] = 4
        self.put('.orbit/vault.json', json.dumps(marker))
        with self.assertRaisesRegex(orbit.OrbitError, 'Unsupported vault'):
            migration.migrate(self.root)


    def test_interrupted_seed_rollback_refuses_unrelated_history(self):
        op = self.interrupt_after_seed()
        self.put('.orbit/commits/unrelated.json', '{}')
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'history'):
            migration.migrate(self.root, 'rollback', operation=op)
        self.assertEqual(self.snapshot(), before)

    def test_legacy_target_cannot_downgrade_format_three(self):
        self.apply()
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'downgrade'):
            migration.migrate(self.root, target_version='0.5.0')
        self.assertEqual(self.snapshot(), before)

    def test_rollback_interrupted_after_marker_resumes_backward(self):
        before = self.snapshot()
        result = self.apply()
        unlink = Path.unlink
        def crash(path, *args, **kwargs):
            if path.parent.name == 'commits':
                raise OSError('interrupted rollback')
            return unlink(path, *args, **kwargs)
        with patch.object(Path, 'unlink', crash):
            with self.assertRaisesRegex(OSError, 'interrupted rollback'):
                migration.migrate(self.root, 'rollback', operation=result['operation'])
        self.assertTrue(migration.status(self.root)['pending'])
        migration.migrate(self.root, 'resume', operation=result['operation'])
        self.assertEqual(self.snapshot(), before)

    def test_existing_integration_bytes_are_seeded_and_preserved(self):
        import replication
        identity = 'a' * 64
        path = '.orbit/integrations/' + identity + '.json'
        text = json.dumps({'source_sha256': identity, 'stage': 'captured', 'custom': {'retain': True}}) + '\r\n'
        self.put(path, text)
        self.apply()
        self.assertEqual((self.root / path).read_bytes(), text.encode())
        evidence = replication.history(self.root, path)
        self.assertIn('retain', json.dumps(evidence))

    def test_format_three_missing_history_refuses_compatibility(self):
        self.apply()
        for path in (self.root / '.orbit/commits').glob('*.json'):
            path.unlink()
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'compatibility'):
            migration.migrate(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_format_one_requires_explicit_first_stage(self):
        marker = json.loads((self.root / '.orbit/vault.json').read_bytes())
        marker['data_format'] = 1
        self.put('.orbit/vault.json', json.dumps(marker))
        before = self.snapshot()
        with self.assertRaisesRegex(orbit.OrbitError, 'target_version=0.5.0'):
            migration.migrate(self.root)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
