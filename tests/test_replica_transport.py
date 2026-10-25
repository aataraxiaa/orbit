"""Adversarial two-replica tests using copied operation and Markdown files.

This is a deterministic filesystem transport simulator, not an iCloud test. Each
replica has its own config, disposable cache, and machine-local recovery state.
"""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'tests'))
import orbit
from test_orbit import note, plan


class ReplicaTransportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='orbit-replica-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.a = self.base / 'replica-a' / 'vault'
        self.b = self.base / 'replica-b' / 'vault'
        self.env_a = self._env('a')
        self.env_b = self._env('b')
        with self.on('a'):
            orbit.setup(str(self.a), 'Test', create=True)
            orbit.apply(self.a, self._plan('Knowledge/Alpha.md', note('alpha', 'Alpha', 'Shared starting point.')))
            orbit.apply(self.a, self._plan('Knowledge/Beta.md', note('beta', 'Beta', 'Second starting point.')))
        self.b.parent.mkdir(parents=True)
        shutil.copytree(self.a, self.b)
        with self.on('b'):
            orbit.setup(str(self.b), 'Test')
        self.assertNotEqual(self.env_a['ORBIT_CONFIG'], self.env_b['ORBIT_CONFIG'])
        self.assertNotEqual(self.env_a['ORBIT_CACHE'], self.env_b['ORBIT_CACHE'])
        self.assertNotEqual(self.env_a['ORBIT_STATE'], self.env_b['ORBIT_STATE'])

    def _env(self, name):
        prefix = self.base / name
        return {'ORBIT_CONFIG': str(prefix / 'config.json'),
                'ORBIT_CACHE': str(prefix / 'cache'),
                'ORBIT_STATE': str(prefix / 'state')}

    @contextlib.contextmanager
    def on(self, replica):
        env = self.env_a if replica == 'a' else self.env_b
        with patch.dict(os.environ, env, clear=False):
            yield self.a if replica == 'a' else self.b

    @staticmethod
    def _plan(path, content):
        return plan(path, content)

    def sync(self, replica, action='reconcile', path=None):
        root = self.a if replica == 'a' else self.b
        args = {'action': action}
        if path is not None:
            args['path'] = path
        with self.on(replica):
            return orbit.dispatch_target('sync', args, root)

    def apply(self, replica, content, *, path='Knowledge/Alpha.md', request_id=None,
              expected_heads=None, observations=None):
        root = self.a if replica == 'a' else self.b
        change = {'path': path, 'content': content, 'reason': 'replica test'}
        current = root / path
        if current.exists():
            change['expected_sha256'] = hashlib.sha256(current.read_bytes()).hexdigest()
        if expected_heads is not None:
            change['expected_heads'] = list(expected_heads)
        if observations is not None:
            change['observations'] = list(observations)
        request_id = request_id or str(uuid.uuid4())
        with self.on(replica):
            return orbit.apply(root, {'summary': 'replica test', 'request_id': request_id, 'changes': [change]})

    @staticmethod
    def _operation_files(root):
        directory = root / '.orbit' / 'commits'
        return {path.name: path for path in directory.glob('*.json')} if directory.exists() else {}

    def deliver_operations(self, source, destination, names=None, *, duplicate=False, reverse=False):
        src = self.a if source == 'a' else self.b
        dst = self.a if destination == 'a' else self.b
        available = self._operation_files(src)
        selected = list(names) if names is not None else sorted(available)
        if reverse:
            selected.reverse()
        target = dst / '.orbit' / 'commits'
        target.mkdir(parents=True, exist_ok=True)
        for name in selected:
            self.assertIn(name, available, f'operation file {name} missing at {source}')
            data = available[name].read_bytes()
            dest = target / name
            if dest.exists():
                self.assertEqual(dest.read_bytes(), data, 'immutable operation ID was reused with different bytes')
            else:
                dest.write_bytes(data)
            if duplicate:
                duplicate_path = target / (name + '.duplicate')
                duplicate_path.write_bytes(data)
                duplicate_path.unlink()

    def deliver_projection(self, source, destination, path='Knowledge/Alpha.md'):
        src = self.a if source == 'a' else self.b
        dst = self.a if destination == 'a' else self.b
        target = dst / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((src / path).read_bytes())

    @staticmethod
    def _conflicts(report):
        return report.get('conflicts', [])

    def heads(self, replica, path='Knowledge/Alpha.md'):
        report = self.sync(replica, action='status')
        value = report.get('heads', {}).get(path)
        if isinstance(value, dict):
            value = value.get('heads', [])
        return tuple(sorted(value or ()))

    def _op_name(self, receipt):
        operation = receipt.get('operation')
        self.assertTrue(operation, receipt)
        candidates = [name for name in self._operation_files(self.a) if operation in name]
        if not candidates:
            candidates = [name for name in self._operation_files(self.b) if operation in name]
        self.assertEqual(len(candidates), 1, f'could not find immutable operation {operation}')
        return candidates[0]

    def test_different_notes_converge_after_each_operation_is_delivered(self):
        a_text = note('alpha', 'Alpha', 'A changed only Alpha.')
        b_text = note('beta', 'Beta', 'B changed only Beta.')
        a_receipt = self.apply('a', a_text)
        b_receipt = self.apply('b', b_text, path='Knowledge/Beta.md')
        self.deliver_operations('a', 'b', [self._op_name(a_receipt)])
        self.deliver_operations('b', 'a', [self._op_name(b_receipt)])
        self.sync('a'); self.sync('b')
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_text(), a_text)
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), a_text)
        self.assertEqual((self.a / 'Knowledge/Beta.md').read_text(), b_text)
        self.assertEqual((self.b / 'Knowledge/Beta.md').read_text(), b_text)
        self.assertFalse(self._conflicts(self.sync('a', 'status')))
        self.assertFalse(self._conflicts(self.sync('b', 'status')))

    def test_same_note_offline_updates_preserve_both_heads_and_do_not_overwrite(self):
        a_text = note('alpha', 'Alpha', 'A offline decision.')
        b_text = note('alpha', 'Alpha', 'B offline decision.')
        ra = self.apply('a', a_text); rb = self.apply('b', b_text)
        a_before = (self.a / 'Knowledge/Alpha.md').read_bytes()
        b_before = (self.b / 'Knowledge/Alpha.md').read_bytes()
        self.deliver_operations('a', 'b', [self._op_name(ra)])
        self.deliver_operations('b', 'a', [self._op_name(rb)])
        report_a = self.sync('a'); report_b = self.sync('b')
        self.assertTrue(self._conflicts(report_a)); self.assertTrue(self._conflicts(report_b))
        self.assertEqual(self.heads('a'), self.heads('b'))
        self.assertEqual(len(self.heads('a')), 2)
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_bytes(), a_before)
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_bytes(), b_before)

    def test_explicit_resolution_names_all_expected_heads_and_converges(self):
        ra = self.apply('a', note('alpha', 'Alpha', 'A decision.'))
        rb = self.apply('b', note('alpha', 'Alpha', 'B decision.'))
        self.deliver_operations('a', 'b', [self._op_name(ra)])
        self.deliver_operations('b', 'a', [self._op_name(rb)])
        self.sync('a'); self.sync('b')
        heads = self.heads('a'); self.assertEqual(len(heads), 2)
        resolved = note('alpha', 'Alpha', 'Reviewed resolution preserves both decisions.')
        receipt = self.apply('a', resolved, expected_heads=heads)
        self.assertEqual(receipt['status'], 'committed')
        self.deliver_operations('a', 'b', [self._op_name(receipt)])
        self.sync('b')
        self.assertEqual(self.heads('a'), self.heads('b'))
        self.assertEqual(len(self.heads('a')), 1)
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_text(), resolved)
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), resolved)

    def test_resolution_with_stale_or_incomplete_expected_heads_is_rejected(self):
        ra = self.apply('a', note('alpha', 'Alpha', 'A.'))
        rb = self.apply('b', note('alpha', 'Alpha', 'B.'))
        self.deliver_operations('a', 'b', [self._op_name(ra)])
        self.deliver_operations('b', 'a', [self._op_name(rb)])
        self.sync('a')
        stale = self.heads('a')
        self.assertEqual(len(stale), 2)
        with self.assertRaises(orbit.OrbitError):
            self.apply('a', note('alpha', 'Alpha', 'Must not resolve stale state.'), expected_heads=stale[:-1])

    def test_reordered_parent_delivery_stays_pending_until_parent_arrives(self):
        first = self.apply('a', note('alpha', 'Alpha', 'Revision one.'))
        second = self.apply('a', note('alpha', 'Alpha', 'Revision two.'))
        first_name, second_name = self._op_name(first), self._op_name(second)
        self.deliver_operations('a', 'b', [second_name])
        pending = self.sync('b')
        self.assertTrue(pending.get('pending'))
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), note('alpha', 'Alpha', 'Shared starting point.'))
        self.deliver_operations('a', 'b', [first_name])
        self.sync('b')
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), note('alpha', 'Alpha', 'Revision two.'))
        self.assertFalse(self.sync('b', 'status').get('pending'))

    def test_duplicate_operation_delivery_has_one_logical_effect(self):
        receipt = self.apply('a', note('alpha', 'Alpha', 'One accepted change.'))
        name = self._op_name(receipt)
        self.deliver_operations('a', 'b', [name], duplicate=True)
        self.sync('b'); once = self.heads('b')
        self.deliver_operations('a', 'b', [name], duplicate=True)
        self.sync('b')
        self.assertEqual(self.heads('b'), once)
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), note('alpha', 'Alpha', 'One accepted change.'))

    def test_same_request_retry_returns_same_operation_and_rejects_payload_change(self):
        request_id = str(uuid.uuid4())
        text = note('alpha', 'Alpha', 'Retry exactly once.')
        change = {'path': 'Knowledge/Alpha.md', 'content': text,
                  'expected_sha256': hashlib.sha256((self.a / 'Knowledge/Alpha.md').read_bytes()).hexdigest(),
                  'reason': 'replica test'}
        request = {'summary': 'replica test', 'request_id': request_id, 'changes': [change]}
        with self.on('a'):
            first = orbit.apply(self.a, request)
        committed_files = len(self._operation_files(self.a))
        with self.on('a'):
            second = orbit.apply(self.a, request)
        self.assertEqual(first['operation'], second['operation'])
        self.assertEqual(len(self._operation_files(self.a)), committed_files)
        with self.assertRaises(orbit.OrbitError):
            with self.on('a'):
                orbit.apply(self.a, {'summary': 'replica test', 'request_id': request_id,
                                     'changes': [{**change, 'content': note('alpha', 'Alpha', 'Different payload.')}]})

    def test_accepted_operation_survives_projection_interruption_and_retry(self):
        request_id = str(uuid.uuid4())
        text = note('alpha', 'Alpha', 'Durable before projection.')
        before = (self.a / 'Knowledge/Alpha.md').read_bytes()
        change = {'path': 'Knowledge/Alpha.md', 'content': text,
                  'expected_sha256': hashlib.sha256(before).hexdigest(), 'reason': 'replica test'}
        request = {'summary': 'interruption retry', 'request_id': request_id, 'changes': [change]}
        original_atomic = orbit.atomic
        target = self.a / 'Knowledge/Alpha.md'

        def fail_materialized_note(path, data):
            if Path(path) == target:
                raise OSError('injected checkout interruption')
            return original_atomic(path, data)

        with self.on('a'), patch.object(orbit, 'atomic', side_effect=fail_materialized_note):
            interrupted = orbit.apply(self.a, request)
        self.assertEqual(interrupted['status'], 'committed')
        self.assertFalse(interrupted['verified'])
        self.assertEqual(interrupted['sync']['status'], 'interrupted')
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_bytes(), before)
        self.assertIn(request_id + '.json', self._operation_files(self.a))
        with self.on('a'):
            retried = orbit.apply(self.a, request)
        self.assertEqual(retried['operation'], request_id)
        self.assertTrue(retried['verified'])
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_text(), text)
        self.assertEqual(len(self._operation_files(self.a)), len(self._operation_files(self.b)) + 1)

    def test_projection_before_operation_is_observed_without_invented_ancestry(self):
        receipt = self.apply('a', note('alpha', 'Alpha', 'Accepted by A.'))
        self.deliver_projection('a', 'b')
        report = self.sync('b')
        history = self.sync('b', action='history', path='Knowledge/Alpha.md')
        observations = history.get('observations', [])
        self.assertTrue(observations, (report, history))
        self.assertTrue(all(not item.get('parents') for item in observations))
        self.assertEqual(len(self.heads('b')), 1, 'a file projection must not become a causal revision')
        self.deliver_operations('a', 'b', [self._op_name(receipt)])
        converged = self.sync('b')
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), note('alpha', 'Alpha', 'Accepted by A.'))
        self.assertFalse(self._conflicts(converged))

    def test_unknown_external_edit_requires_explicit_observation_adoption(self):
        external = note('alpha', 'Alpha', 'External editor bytes with unique marker.')
        (self.a / 'Knowledge/Alpha.md').write_bytes(external.encode('utf-8'))
        report = self.sync('a')
        history = self.sync('a', action='history', path='Knowledge/Alpha.md')
        observations = history.get('observations', [])
        self.assertTrue(observations, (report, history))
        observation = observations[0]
        self.assertEqual(observation.get('content'), external)
        self.assertFalse(observation.get('parents'))
        before_heads = self.heads('a')
        receipt = self.apply('a', external, expected_heads=before_heads,
                             observations=[observation['id']])
        self.assertEqual(receipt['status'], 'committed')
        self.assertEqual((self.a / 'Knowledge/Alpha.md').read_text(), external)
        self.assertFalse(self._conflicts(self.sync('a', 'status')))

    def test_read_and_search_do_not_create_resolution_history_for_unknown_projection(self):
        external = note('alpha', 'Alpha', 'Unexplained projection bytes arrive first.')
        (self.a / 'Knowledge/Alpha.md').write_text(external)
        self.deliver_projection('a', 'b')
        before = {name: hashlib.sha256(path.read_bytes()).hexdigest()
                  for name, path in self._operation_files(self.b).items()}
        with self.on('b'):
            for _ in range(2):
                with self.assertRaises(orbit.OrbitError):
                    orbit.read(self.b, 'Knowledge/Alpha.md')
                result = orbit.search(self.b, 'Shared starting point')
                self.assertNotIn('Knowledge/Alpha.md', [item['path'] for item in result['results']])
        after = {name: hashlib.sha256(path.read_bytes()).hexdigest()
                 for name, path in self._operation_files(self.b).items()}
        self.assertEqual(after, before, 'read/search must never author resolution history')

    def test_reversed_delivery_order_does_not_make_arrival_the_winner(self):
        first = self.apply('a', note('alpha', 'Alpha', 'Earlier revision.'))
        second = self.apply('a', note('alpha', 'Alpha', 'Later revision.'))
        self.deliver_operations('a', 'b', [self._op_name(second), self._op_name(first)])
        self.sync('b')
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), note('alpha', 'Alpha', 'Later revision.'))
        self.assertEqual(self.heads('a'), self.heads('b'))

    def test_independent_revisions_with_same_bytes_are_not_collapsed(self):
        shared = note('alpha', 'Alpha', 'Same bytes, independent accepted histories.')
        ra = self.apply('a', shared); rb = self.apply('b', shared)
        self.deliver_operations('a', 'b', [self._op_name(ra)])
        self.deliver_operations('b', 'a', [self._op_name(rb)])
        self.sync('a'); self.sync('b')
        self.assertEqual(len(self.heads('a')), 2)
        self.assertEqual(self.heads('a'), self.heads('b'))
        self.assertTrue(self._conflicts(self.sync('a', 'status')))

    def test_cache_deletion_does_not_remove_history_or_change_heads(self):
        ra = self.apply('a', note('alpha', 'Alpha', 'A version.'))
        rb = self.apply('b', note('alpha', 'Alpha', 'B version.'))
        self.deliver_operations('a', 'b', [self._op_name(ra)])
        self.deliver_operations('b', 'a', [self._op_name(rb)])
        self.sync('a'); self.sync('b')
        expected = self.heads('a')
        shutil.rmtree(self.env_a['ORBIT_CACHE'], ignore_errors=True)
        self.assertEqual(self.heads('a'), expected)
        history = self.sync('a', action='history', path='Knowledge/Alpha.md')
        self.assertGreaterEqual(len(history.get('revisions', [])), 3)

    def test_replica_restart_keeps_machine_local_state_and_replays_history(self):
        receipt = self.apply('a', note('alpha', 'Alpha', 'Survives restart.'))
        state_path = Path(self.env_b['ORBIT_STATE'])
        self.deliver_operations('a', 'b', [self._op_name(receipt)])
        process_env = os.environ.copy()
        process_env.update(self.env_b)
        process_env['PYTHONDONTWRITEBYTECODE'] = '1'
        process = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/orbit.py'), '--vault', str(self.b), 'sync', '--mode', 'reconcile'],
            env=process_env, cwd=self.base, capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertFalse(process.stderr)
        self.assertEqual(json.loads(process.stdout)['status'], 'ready')
        before = sorted(str(p.relative_to(state_path)) for p in state_path.rglob('*') if p.is_file())
        with self.on('b'):
            restarted = orbit.dispatch_target('sync', {'action': 'status'}, self.b)
        after = sorted(str(p.relative_to(state_path)) for p in state_path.rglob('*') if p.is_file())
        self.assertEqual(after, before)
        self.assertEqual(restarted.get('heads'), self.sync('a', 'status').get('heads'))

    def test_unanchored_external_bytes_survive_while_remote_parent_is_missing(self):
        external = note('alpha', 'Alpha', 'Unanchored local edit survives pending dependency.')
        (self.b / 'Knowledge/Alpha.md').write_text(external)
        self.sync('b')
        first = self.apply('a', note('alpha', 'Alpha', 'A update one.'))
        second = self.apply('a', note('alpha', 'Alpha', 'A update two.'))
        self.deliver_operations('a', 'b', [self._op_name(second)])
        report = self.sync('b')
        self.assertTrue(report.get('pending'))
        self.assertEqual((self.b / 'Knowledge/Alpha.md').read_text(), external)
        self.deliver_operations('a', 'b', [self._op_name(first)])
        self.sync('b')
        history = self.sync('b', action='history', path='Knowledge/Alpha.md')
        self.assertTrue(any(item.get('content') == external for item in history.get('observations', [])))

    def test_setup_retry_recovers_when_genesis_seed_fails_after_format_marker(self):
        root = self.base / 'crash-retry' / 'vault'
        env = self._env('crash-retry')
        with patch.dict(os.environ, env, clear=False):
            with patch('replication.seed', side_effect=OSError('injected seed interruption')):
                with self.assertRaisesRegex(OSError, 'injected seed interruption'):
                    orbit.setup(str(root), 'Retry', create=True)
            marker = json.loads((root / '.orbit/vault.json').read_text())
            self.assertEqual(marker['data_format'], 3)
            self.assertFalse(list((root / '.orbit/commits').glob('*.json')))
            orbit.setup(str(root), 'Retry')
            status = orbit.dispatch_target('sync', {'action': 'status'}, root)
            self.assertEqual(status['status'], 'ready', status)

    def test_two_processes_with_distinct_configs_share_one_local_lock(self):
        root = self.a
        entered = self.base / 'lock-first-entered'
        still_holding = self.base / 'lock-first-holding'
        second_entered = self.base / 'lock-second-entered'
        script = f"""
import pathlib, sys, time
sys.path.insert(0, {str(ROOT / 'scripts')!r})
import orbit
root, entered, holding = map(pathlib.Path, sys.argv[1:4])
second = pathlib.Path(sys.argv[4]) if sys.argv[4] else None
with orbit.lock(root):
    if second:
        second.write_text('held' if holding.exists() else 'free')
    else:
        entered.write_text('entered')
        holding.write_text('yes')
        time.sleep(0.8)
        holding.unlink()
"""
        first_env = os.environ.copy()
        first_env.pop('ORBIT_STATE', None)
        first_env.update({'ORBIT_CONFIG': str(self.base / 'machine-one' / 'config.json'),
                          'HOME': str(self.base / 'same-user-home'),
                          'PYTHONDONTWRITEBYTECODE': '1'})
        second_env = os.environ.copy()
        second_env.pop('ORBIT_STATE', None)
        second_env.update({'ORBIT_CONFIG': str(self.base / 'machine-two' / 'config.json'),
                           'HOME': str(self.base / 'same-user-home'),
                           'PYTHONDONTWRITEBYTECODE': '1'})
        first = subprocess.Popen([sys.executable, '-c', script, str(root), str(entered), str(still_holding), ''],
                                 env=first_env, cwd=self.base, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = __import__('time').monotonic() + 10
            while not entered.exists() and __import__('time').monotonic() < deadline:
                __import__('time').sleep(0.01)
            if not entered.exists():
                first.kill()
                first_out, first_err = first.communicate(timeout=5)
                self.fail(f'first process never acquired the lock: stdout={first_out!r} stderr={first_err!r}')
            second = subprocess.Popen([sys.executable, '-c', script, str(root), str(entered), str(still_holding), str(second_entered)],
                                      env=second_env, cwd=self.base, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            second_out, second_err = second.communicate(timeout=10)
            first_out, first_err = first.communicate(timeout=10)
            self.assertEqual((first.returncode, first_err), (0, ''))
            self.assertEqual((second.returncode, second_err), (0, ''), second_out)
            self.assertEqual(second_entered.read_text(), 'free',
                             'different configs selected different local locks for the same vault')
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
