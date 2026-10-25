import itertools
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import replication as r


def note(identity, body):
    return '---\nid: ' + identity + '\ntitle: Test\ntype: knowledge\nsummary: Test\n---\n' + body + '\n'


class ReplicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'config.json'), 'ORBIT_STATE': str(self.base / 'state')})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.a = self.base / 'a'
        (self.a / '.orbit').mkdir(parents=True)
        (self.a / '.orbit/vault.json').write_text(json.dumps({'id': str(uuid.uuid4()), 'data_format': 3}))
        self.initial = {'A.md': note('a', 'original A'), 'B.md': note('b', 'original B')}
        for path, text in self.initial.items():
            (self.a / path).write_bytes(text.encode())
        self.seed = r.seed(self.a, self.initial)
        self.b = self.base / 'b'
        shutil.copytree(self.a, self.b)

    def write(self, root, path, text, **extra):
        return {'path': path, 'before': (root / path).read_bytes().decode() if (root / path).exists() else None,
                'after': text, 'reason': 'test', **extra}

    def deliver(self, source, target, operation=None):
        for directory in ('commits', 'observations'):
            destination = target / '.orbit' / directory
            destination.mkdir(exist_ok=True)
            for path in (source / '.orbit' / directory).glob('*.json'):
                if operation is None or path.stem == operation or directory == 'observations':
                    shutil.copyfile(path, destination / path.name)

    def test_different_files_converge_and_replay_has_no_new_history(self):
        a = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'new A'))])
        b = r.commit(self.b, [self.write(self.b, 'B.md', note('b', 'new B'))])
        self.assertTrue(a['verified'])
        self.assertTrue(b['verified'])
        self.deliver(self.a, self.b)
        self.deliver(self.b, self.a)
        for root in (self.a, self.b):
            self.assertEqual(r.reconcile(root)['status'], 'ready')
            self.assertEqual((root / 'A.md').read_text(), note('a', 'new A'))
            self.assertEqual((root / 'B.md').read_text(), note('b', 'new B'))
            self.assertEqual(len(list((root / '.orbit/commits').glob('*'))), 3)
        self.assertEqual(r.inspect(self.a), r.inspect(self.b))

    def test_same_file_resolution_and_late_branch(self):
        c = self.base / 'c'
        shutil.copytree(self.a, c)
        for root, body in ((self.a, 'left'), (self.b, 'right'), (c, 'late')):
            r.commit(root, [self.write(root, 'A.md', note('a', body))])
        self.deliver(self.b, self.a)
        state = r.reconcile(self.a)
        self.assertEqual(state['blocked_paths'], ['A.md'])
        self.assertEqual(len(state['conflicts'][0]['heads']), 2)
        with self.assertRaisesRegex(orbit.OrbitError, 'expected_heads'):
            r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'bad merge'))])
        resolution = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'resolved'), expected_heads=state['heads']['A.md'])])
        self.assertTrue(resolution['verified'])
        self.deliver(self.a, self.b)
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        self.assertEqual((self.b / 'A.md').read_text(), note('a', 'resolved'))
        self.deliver(c, self.a)
        self.assertEqual(len(r.reconcile(self.a)['conflicts'][0]['heads']), 2)
        contents = {v['content'] for v in r.history(self.a, 'A.md')['revisions']}
        self.assertTrue({note('a', x) for x in ('left', 'right', 'late', 'resolved')} <= contents)

    def test_external_observation_and_explicit_adoption(self):
        edited = note('a', 'external\r\nexact')
        (self.a / 'A.md').write_bytes(edited.encode())
        status = r.inspect(self.a)
        self.assertEqual(status['status'], 'conflicted')
        self.assertFalse((self.a / '.orbit/observations').exists())
        status = r.reconcile(self.a)
        ids = status['conflicts'][0]['observations']
        self.assertEqual((self.a / 'A.md').read_bytes(), edited.encode())
        with self.assertRaisesRegex(orbit.OrbitError, 'expected_heads'):
            r.commit(self.a, [self.write(self.a, 'A.md', edited, observations=ids)])
        result = r.commit(self.a, [self.write(self.a, 'A.md', edited, observations=ids, expected_heads=status['heads']['A.md'])])
        self.assertEqual(result['sync']['status'], 'ready')
        evidence = r.history(self.a, 'A.md')
        self.assertEqual(evidence['observations'][0]['content'], edited)
        self.assertEqual(evidence['current']['content'], edited)
        self.assertEqual(evidence['current']['sha256'], orbit.digest(edited.encode()))

    def test_markdown_before_envelope_does_not_invent_ancestry(self):
        result = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'remote'))])
        shutil.copyfile(self.a / 'A.md', self.b / 'A.md')
        self.assertEqual(r.reconcile(self.b)['status'], 'conflicted')
        self.deliver(self.a, self.b, result['operation'])
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        self.assertEqual(len(list((self.b / '.orbit/commits').glob('*'))), 2)

    def test_missing_parent_arrival_and_retry(self):
        first = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'first'))])
        request = str(uuid.uuid4())
        writes = [self.write(self.a, 'A.md', note('a', 'second'))]
        second = r.commit(self.a, writes, request_id=request, request_digest='logical request')
        self.deliver(self.a, self.b, second['operation'])
        self.assertEqual(r.reconcile(self.b)['status'], 'pending')
        self.assertEqual((self.b / 'A.md').read_text(), self.initial['A.md'])
        with self.assertRaises(orbit.OrbitError):
            r.operation(self.b, second['operation'])
        self.deliver(self.a, self.b, first['operation'])
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        self.assertEqual((self.b / 'A.md').read_text(), note('a', 'second'))
        self.assertEqual(r.retry(self.a, request, 'logical request')['operation'], request)
        with self.assertRaisesRegex(orbit.OrbitError, 'different content'):
            r.retry(self.a, request, 'other')

    def test_assets_hold_entire_batch_until_arrival(self):
        raw = b'original source'
        digest = orbit.digest(raw)
        rel = 'Sources/assets/' + digest + '.txt'
        (self.a / rel).parent.mkdir(parents=True)
        (self.a / rel).write_bytes(raw)
        result = r.commit(self.a, [self.write(self.a, 'A.md', note('a', '[[' + rel + ']]')),
                                   self.write(self.a, 'B.md', note('b', 'batch'))])
        self.deliver(self.a, self.b)
        self.assertEqual(r.reconcile(self.b)['status'], 'pending')
        self.assertEqual((self.b / 'B.md').read_text(), self.initial['B.md'])
        (self.b / rel).parent.mkdir(parents=True)
        (self.b / rel).write_bytes(raw)
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        self.assertEqual((self.b / 'B.md').read_text(), note('b', 'batch'))

    def test_projection_failure_retains_durable_receipt(self):
        original = orbit.atomic
        def fail(path, data):
            if Path(path).name == 'A.md':
                raise OSError('simulated disk error')
            return original(path, data)
        with patch.object(orbit, 'atomic', side_effect=fail):
            result = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'durable'))])
        self.assertEqual(result['status'], 'committed')
        self.assertEqual(result['durability'], 'local')
        self.assertFalse(result['verified'])
        self.assertEqual(r.operation(self.a, result['operation'])['writes'][0]['after'], note('a', 'durable'))
        self.assertEqual(r.reconcile(self.a)['status'], 'ready')
        self.assertEqual((self.a / 'A.md').read_text(), note('a', 'durable'))

    def test_corruption_blocks_all_paths_without_writes(self):
        (self.a / '.orbit/commits/bad.json').write_text('{}')
        report = r.inspect(self.a)
        self.assertEqual(report['status'], 'invalid')
        self.assertEqual(report['blocked_paths'], ['A.md', 'B.md'])
        self.assertEqual(r.reconcile(self.a)['materialized'], [])

    def test_rename_and_delete_keep_identity_and_conflict_with_stale_edit(self):
        r.commit(self.a, [self.write(self.a, 'A.md', None), self.write(self.a, 'New.md', note('a', 'renamed'))])
        self.assertFalse((self.a / 'A.md').exists())
        r.commit(self.b, [self.write(self.b, 'A.md', note('a', 'stale'))])
        self.deliver(self.b, self.a)
        state = r.reconcile(self.a)
        self.assertEqual(state['blocked_paths'], ['A.md', 'New.md'])
        self.assertEqual(len(state['conflicts'][0]['heads']), 2)

    def test_seed_preview_and_unformatted_identity(self):
        folder = self.base / 'legacy'
        (folder / '.orbit').mkdir(parents=True)
        (folder / '.orbit/vault.json').write_text(json.dumps({'id': str(uuid.uuid4()), 'data_format': 2}))
        files = {'Plain.md': '# Plain\n'}
        (folder / 'Plain.md').write_text(files['Plain.md'])
        preview = r.seed_preview(folder, files)
        self.assertFalse((folder / preview['path']).exists())
        self.assertEqual(r.seed(folder, files)['operation'], preview['operation'])
        self.assertEqual(orbit.digest((folder / preview['path']).read_bytes()), preview['sha256'])
        result = r.commit(folder, [self.write(folder, 'Plain.md', note('formatted', 'Plain'))])
        self.assertTrue(result['verified'])
        self.assertEqual(r.inspect(folder)['status'], 'ready')
        self.assertEqual(len(r.inspect(folder)['heads']['Plain.md']), 1)

    def test_all_delivery_orders_preserve_identical_heads(self):
        first = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'one'))])
        second = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'two'))])
        third = r.commit(self.b, [self.write(self.b, 'A.md', note('a', 'concurrent'))])
        sources = {first['operation']: self.a, second['operation']: self.a, third['operation']: self.b}
        reports = []
        for number, order in enumerate(itertools.permutations(sources)):
            root = self.base / ('order-' + str(number))
            root.mkdir()
            (root / '.orbit/commits').mkdir(parents=True)
            shutil.copyfile(self.a / '.orbit/vault.json', root / '.orbit/vault.json')
            for path, text in self.initial.items():
                (root / path).write_text(text)
            self.deliver(self.a, root, self.seed['operation'])
            for operation_id in order:
                self.deliver(sources[operation_id], root, operation_id)
                r.reconcile(root)
                self.deliver(sources[operation_id], root, operation_id)
            reports.append(r.inspect(root))
        self.assertTrue(all(report == reports[0] for report in reports))
        self.assertEqual(len(reports[0]['conflicts'][0]['heads']), 2)

    def test_stale_physical_bytes_cannot_parent_unread_remote_head(self):
        accepted = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'remote'))])
        self.deliver(self.a, self.b, accepted['operation'])
        with self.assertRaisesRegex(orbit.OrbitError, 'accepted head'):
            r.commit(self.b, [self.write(self.b, 'A.md', note('a', 'stale overwrite'))])
        self.assertEqual(len(list((self.b / '.orbit/commits').glob('*'))), 2)

    def test_rename_descendant_removes_late_old_location(self):
        r.commit(self.a, [self.write(self.a, 'A.md', None), self.write(self.a, 'New.md', note('a', 'renamed'))])
        r.commit(self.a, [self.write(self.a, 'New.md', note('a', 'later'))])
        self.deliver(self.a, self.b)
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        (self.b / 'A.md').write_text(self.initial['A.md'])
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        self.assertFalse((self.b / 'A.md').exists())
        self.assertEqual((self.b / 'New.md').read_text(), note('a', 'later'))

    def test_concurrent_path_collision_preserves_both_entities(self):
        r.commit(self.a, [self.write(self.a, 'Same.md', note('left', 'left'))])
        r.commit(self.b, [self.write(self.b, 'Same.md', note('right', 'right'))])
        self.deliver(self.a, self.b)
        self.deliver(self.b, self.a)
        for root in (self.a, self.b):
            report = r.reconcile(root)
            self.assertEqual(report['blocked_paths'], ['Same.md'])
            self.assertEqual(len(report['conflicts']), 2)
        self.assertEqual(r.inspect(self.a), r.inspect(self.b))
        state = r.inspect(self.a)
        chosen = note('right', 'right')
        with self.assertRaisesRegex(orbit.OrbitError, 'exact union'):
            r.commit(self.a, [self.write(self.a, 'Same.md', chosen, expected_heads=state['heads']['Same.md'][:1])])
        result = r.commit(self.a, [self.write(self.a, 'Same.md', chosen, expected_heads=state['heads']['Same.md'])])
        self.assertTrue(result['verified'])
        self.assertEqual(result['sync']['status'], 'ready')
        self.deliver(self.a, self.b)
        self.assertEqual(r.reconcile(self.b)['status'], 'ready')
        for root in (self.a, self.b):
            self.assertEqual((root / 'Same.md').read_text(), chosen)
            revisions = r.history(root, 'Same.md')['revisions']
            self.assertIn(note('left', 'left'), {v['content'] for v in revisions})
            self.assertTrue(any(v.get('retired') for v in revisions))
        self.assertTrue(r.commit(self.a, [self.write(self.a, 'Same.md', note('right', 'later'))])['verified'])

    def test_concurrent_integration_updates_preserve_evidence(self):
        digest = 'a' * 64
        path = '.orbit/integrations/' + digest + '.json'
        initial = json.dumps({'source_sha256': digest, 'stage': 'captured', 'version': 1})
        r.commit(self.a, [self.write(self.a, path, initial)])
        self.deliver(self.a, self.b)
        r.reconcile(self.b)
        for root, marker in ((self.a, 'left evidence'), (self.b, 'right evidence')):
            r.commit(root, [self.write(root, path, json.dumps({'source_sha256': digest, 'stage': 'extracted', 'version': 2, 'evidence': marker}))])
        self.deliver(self.a, self.b)
        report = r.reconcile(self.b)
        self.assertEqual(report['blocked_paths'], [path])
        self.assertEqual(len(report['conflicts'][0]['heads']), 2)
        self.assertEqual(len(r.history(self.b, path)['revisions']), 3)

    def test_untracked_plain_observation_can_gain_metadata(self):
        (self.a / 'Plain.md').write_text('# Plain\n')
        report = r.reconcile(self.a)
        conflict = next(c for c in report['conflicts'] if c['entity'] == 'path:Plain.md')
        result = r.commit(self.a, [self.write(self.a, 'Plain.md', note('new-id', 'Plain'),
                                           expected_heads=[], observations=conflict['observations'])])
        self.assertTrue(result['verified'])
        self.assertEqual(result['sync']['status'], 'ready')
        self.assertEqual(len(r.history(self.a, 'Plain.md')['observations']), 1)

    def test_duplicate_metadata_identity_across_legacy_and_named_entities_blocks_both(self):
        (self.a / 'Plain.md').write_text('# Plain\n')
        state = r.reconcile(self.a)
        conflict = next(c for c in state['conflicts'] if c['entity'] == 'path:Plain.md')
        result = r.commit(self.a, [self.write(self.a, 'Plain.md', note('a', 'duplicate'),
                                           expected_heads=[], observations=conflict['observations'])])
        self.assertEqual(result['sync']['status'], 'conflicted')
        self.assertEqual(result['sync']['blocked_paths'], ['A.md', 'Plain.md'])
        self.assertEqual((self.a / 'Plain.md').read_text(), '# Plain\n')

    def test_dry_run_checks_heads_without_capture_or_projection(self):
        r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'left'))])
        r.commit(self.b, [self.write(self.b, 'A.md', note('a', 'right'))])
        self.deliver(self.b, self.a)
        state = r.inspect(self.a)
        before = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        for heads in ([], state['heads']['A.md'][:1], ['stale']):
            with self.assertRaisesRegex(orbit.OrbitError, 'expected_heads'):
                r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'resolved'), expected_heads=heads)], dry_run=True)
        result = r.commit(self.a, [self.write(self.a, 'A.md', note('a', 'resolved'),
                                            expected_heads=state['heads']['A.md'])], dry_run=True)
        self.assertEqual(result['status'], 'preview')
        after = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_dry_run_adopts_ephemeral_observation_without_publishing_it(self):
        (self.a / 'Plain.md').write_text('# External plain note\n')
        state = r.inspect(self.a)
        conflict = next(c for c in state['conflicts'] if c['entity'] == 'path:Plain.md')
        before = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        writes = [self.write(self.a, 'Plain.md', note('formatted', 'external'),
                             expected_heads=[], observations=conflict['observations'])]
        result = r.commit(self.a, writes, dry_run=True)
        self.assertEqual(result['status'], 'preview')
        self.assertFalse((self.a / '.orbit/observations').exists())
        after = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertTrue(r.commit(self.a, writes)['verified'])

    def test_dry_run_retry_never_reconciles_accepted_operation(self):
        request_id = str(uuid.uuid4())
        writes = [self.write(self.a, 'A.md', note('a', 'accepted'))]
        result = r.commit(self.a, writes, request_id=request_id)
        (self.a / 'A.md').write_text(self.initial['A.md'])
        before = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        preview = r.commit(self.a, writes, request_id=request_id, dry_run=True)
        self.assertEqual(preview['status'], 'preview')
        self.assertTrue(preview['already_committed'])
        self.assertEqual(preview['operation'], result['operation'])
        after = {p.relative_to(self.base).as_posix(): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        with self.assertRaisesRegex(orbit.OrbitError, 'different content'):
            r.commit(self.a, writes, request_id=request_id, request_digest='different', dry_run=True)

    def test_nested_lock_and_missing_history(self):
        with r.local_lock(self.a):
            with r.local_lock(self.a):
                self.assertEqual(r.inspect(self.a)['status'], 'ready')
        shutil.rmtree(self.a / '.orbit/commits')
        self.assertEqual(r.inspect(self.a)['status'], 'invalid')
        self.assertEqual(r.reconcile(self.a)['materialized'], [])


if __name__ == '__main__':
    unittest.main()
