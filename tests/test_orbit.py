import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit


def note(identity='atlas', title='Atlas', body='Staged deployment avoids a big-bang rollout.', aliases=None, status='current'):
    fields = {'id': identity, 'title': title, 'type': 'project', 'summary': body.splitlines()[0], 'aliases': aliases or [], 'status': status}
    return '---\n' + '\n'.join(f'{k}: {json.dumps(v)}' for k, v in fields.items()) + '\n---\n# ' + title + '\n\n' + body + '\n'


def plan(path='Knowledge/Atlas.md', content=None, sha=None):
    return {'summary': 'save test', 'changes': [{'path': path, 'content': content or note(), 'expected_sha256': sha, 'reason': 'User requested save'}]}


class VaultTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / 'vault with spaces'
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'config.json')})
        self.env.start()
        orbit.setup(str(self.root), create=True)

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_setup_requires_explicit_creation_and_preserves_files(self):
        with self.assertRaises(orbit.OrbitError): orbit.setup(str(self.base / 'missing'))
        p = self.root / 'manual.md'; p.write_text('User-owned content')
        original_rules = (self.root / 'ORBIT.md').read_bytes()
        orbit.setup(str(self.root))
        self.assertEqual(p.read_text(), 'User-owned content')
        self.assertEqual((self.root / 'ORBIT.md').read_bytes(), original_rules)
        self.assertEqual(orbit.vault(), self.root.resolve())

    def run_cli(self, *args, config=None, input=None):
        env = os.environ.copy()
        env.pop('ORBIT_VAULT', None)
        env['ORBIT_CONFIG'] = str(config or self.base / 'config.json')
        return subprocess.run([sys.executable, str(Path(orbit.__file__)), *args],
                              cwd=self.base, env=env, input=input, capture_output=True, text=True)

    def test_setup_in_fresh_processes_preserves_shared_vault_and_config(self):
        marker = self.root / '.orbit/vault.json'
        original_marker = marker.read_bytes()
        rules = self.root / 'ORBIT.md'
        rules.write_text('# Our rules\nKeep knowledge in Notes/.\n')
        manual = self.root / 'manual.md'
        manual.write_text('User-owned content\n')
        config = self.base / 'config.json'
        settings = json.loads(config.read_text())
        settings['custom'] = {'preferred_folder': 'Notes', 'keep': [1, 2]}
        config.write_text(json.dumps(settings))
        second_config = self.base / 'other host' / 'config.json'
        second_config.parent.mkdir()
        second_config.write_text(json.dumps({'other_host': {'keep': True}}))

        for current_config in (config, config, second_config):
            with self.subTest(config=current_config):
                result = self.run_cli('setup', str(self.root), config=current_config)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt['vault_id'], json.loads(original_marker)['id'])
                self.assertEqual(receipt['vault'], str(self.root.resolve()))
                self.assertEqual(marker.read_bytes(), original_marker)
                self.assertEqual(rules.read_text(), '# Our rules\nKeep knowledge in Notes/.\n')
                self.assertEqual(manual.read_text(), 'User-owned content\n')
                check = self.run_cli('doctor', config=current_config)
                self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual(json.loads(config.read_text()), settings)
        self.assertEqual(json.loads(second_config.read_text())['other_host'], {'keep': True})

    def test_setup_retry_after_config_write_failure_preserves_initialized_vault(self):
        root = self.base / 'partially initialized'
        config_parent = self.base / 'blocked config parent'
        config_parent.write_text('This file prevents the config directory from being created.')
        config = config_parent / 'config.json'
        failed = self.run_cli('setup', str(root), '--create', config=config)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('error', json.loads(failed.stderr))
        marker = root / '.orbit/vault.json'
        original_marker = marker.read_bytes()
        rules = root / 'ORBIT.md'
        rules.write_text('# Preserve these rules after retry\n')
        manual = root / 'manual.md'
        manual.write_text('Written between setup attempts\n')
        config_parent.unlink()

        retried = self.run_cli('setup', str(root), config=config)
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertEqual(marker.read_bytes(), original_marker)
        self.assertEqual(rules.read_text(), '# Preserve these rules after retry\n')
        self.assertEqual(manual.read_text(), 'Written between setup attempts\n')
        self.assertEqual(json.loads(config.read_text())['vault'], str(root.resolve()))

    def test_second_host_updates_one_setup_record_with_current_hash(self):
        path = 'Knowledge/Orbit setup check.md'
        original = note('setup-check', 'Orbit setup check', 'First host verified.\nUser annotation stays.')
        original = original.replace('---\n# ', 'custom: "preserve me"\n---\n# ')
        first = self.run_cli('apply', '-', input=json.dumps(plan(path, original)))
        self.assertEqual(first.returncode, 0, first.stderr)
        second_config = self.base / 'second-host.json'
        bound = self.run_cli('setup', str(self.root), config=second_config)
        self.assertEqual(bound.returncode, 0, bound.stderr)
        before = self.run_cli('read', path, config=second_config)
        self.assertEqual(before.returncode, 0, before.stderr)
        sha = json.loads(before.stdout)['sha256']
        updated = original + '\nSecond host receipt: verified-cross-host-write.\n'
        saved = self.run_cli('apply', '-', config=second_config, input=json.dumps(plan(path, updated, sha)))
        self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertEqual(json.loads(saved.stdout)['status'], 'committed')
        self.assertEqual((self.root / path).read_text(), updated)
        found = self.run_cli('search', 'verified-cross-host-write', config=second_config)
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(json.loads(found.stdout)['total'], 1)
        self.assertEqual(list((self.root / 'Knowledge').glob('*.md')), [self.root / path])

    def test_save_search_read_and_manual_edit(self):
        result = orbit.apply(self.root, plan())
        self.assertTrue(result['verified'])
        self.assertEqual(orbit.search(self.root, 'staged rollout')['results'][0]['path'], 'Knowledge/Atlas.md')
        read = orbit.read(self.root, 'Knowledge/Atlas.md')
        self.assertEqual(len(read['sha256']), 64)
        p = self.root / 'Knowledge/Atlas.md'
        p.write_text(p.read_text() + '\nManual detail: bluegreen migration.\n')
        self.assertEqual(orbit.search(self.root, 'bluegreen')['total'], 1)

    def test_alias_and_canonical_ranking(self):
        orbit.apply(self.root, plan(content=note(aliases=['Launch sequence'])))
        (self.root / 'log.md').write_text(('launch sequence blah ' * 100))
        self.assertEqual(orbit.search(self.root, 'Launch sequence')['results'][0]['path'], 'Knowledge/Atlas.md')

    def test_conflicting_update_is_rejected_without_partial_write(self):
        orbit.apply(self.root, plan())
        original = orbit.read(self.root, 'Knowledge/Atlas.md')['sha256']
        p = self.root / 'Knowledge/Atlas.md'
        p.write_text(p.read_text() + 'User edit\n')
        batch = plan('Knowledge/New.md', note('new', 'New'))
        batch['changes'] += plan(content=note(body='Changed'), sha=original)['changes']
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, batch)
        self.assertFalse((self.root / 'Knowledge/New.md').exists())
        self.assertIn('User edit', p.read_text())

    def test_updates_preserve_identity_and_noop(self):
        orbit.apply(self.root, plan())
        sha = orbit.read(self.root, 'Knowledge/Atlas.md')['sha256']
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan(content=note('different'), sha=sha))
        self.assertEqual(orbit.apply(self.root, plan(sha=sha))['status'], 'unchanged')
        self.assertEqual(orbit.apply(self.root, plan(content=note(body='New decision'), sha=sha))['status'], 'committed')

    def test_links_across_batch_and_backlinks(self):
        batch = plan(content=note(body='Depends on [[Knowledge/Rollout]] — rollback must work.'))
        batch['changes'] += plan('Knowledge/Rollout.md', note('rollout', 'Rollout', 'A reusable pattern.'))['changes']
        orbit.apply(self.root, batch)
        graph = orbit.context(self.root, 'Rollout')
        self.assertEqual(graph['total'], 2)
        self.assertFalse(orbit.doctor(self.root)['issues'])

    def test_bad_links_duplicate_ids_and_ambiguous_names(self):
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan(content=note(body='[[Missing]]')))
        orbit.apply(self.root, plan())
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan('Knowledge/Duplicate.md'))
        orbit.apply(self.root, plan('Elsewhere/Atlas.md', note('other-atlas')))
        with self.assertRaises(orbit.OrbitError): orbit.context(self.root, 'Atlas')
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan('Knowledge/Ref.md', note('ref', 'Ref', '[[Atlas]]')))
        orbit.apply(self.root, plan('Knowledge/Ref.md', note('ref', 'Ref', '[[Knowledge/Atlas]]')))

    def test_traversal_and_symlinks(self):
        for path in ('../escape.md', '/tmp/escape.md', '.orbit/foo.md'):
            with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan(path))
        (self.root / 'out').symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan('out/escape.md'))
        self.assertFalse((self.base / 'escape.md').exists())

    def test_internal_symlink_is_rejected(self):
        other = self.base / 'other'; other.mkdir()
        (self.root / '.orbit').rename(self.root / '.old')
        (self.root / '.orbit').symlink_to(other, target_is_directory=True)
        with self.assertRaises(orbit.OrbitError): orbit.setup(str(self.root))

    def test_capture_is_byte_exact_deduplicated_and_linkable(self):
        src = self.base / 'file.pdf'; src.write_bytes(b'%PDF binary\x00\xff')
        captured = orbit.capture(self.root, str(src))
        self.assertEqual((self.root / captured['path']).read_bytes(), src.read_bytes())
        self.assertEqual(orbit.capture(self.root, str(src))['status'], 'already-captured')
        self.assertEqual(captured['integration'], 'not-performed')
        orbit.apply(self.root, plan('Sources/File.md', note('source', 'File', '[[' + captured['path'] + ']]')))

    def test_captured_markdown_cannot_be_rewritten(self):
        src = self.base / 'original.md'; src.write_text(note('original', 'Original'))
        captured = orbit.capture(self.root, str(src))
        with self.assertRaises(orbit.OrbitError):
            orbit.apply(self.root, plan(captured['path'], note('original', 'Original', 'Modified'), captured['sha256']))
        self.assertEqual((self.root / captured['path']).read_bytes(), src.read_bytes())

    def test_recovery_preserves_crlf_bytes(self):
        original = note().replace('\n', '\r\n')
        p = self.root / 'Knowledge/Atlas.md'; p.parent.mkdir(exist_ok=True); p.write_bytes(original.encode())
        opid = '00000000-0000-0000-0000-000000000002'
        record = {'id': opid, 'status': 'prepared', 'writes': [{'path': 'Knowledge/Atlas.md', 'before': original, 'after': note(body='Changed')}]}
        orbit.atomic(self.root / '.orbit/operations' / (opid + '.json'), orbit.encode(record))
        orbit.recover(self.root, opid, rollback=True)
        self.assertEqual(p.read_bytes(), original.encode())

    def test_preview_writes_nothing(self):
        self.assertEqual(orbit.apply(self.root, plan(), dry_run=True)['status'], 'preview')
        self.assertFalse((self.root / 'Knowledge/Atlas.md').exists())

    def test_interrupted_batch_recovery(self):
        batch = plan()
        batch['changes'] += plan('Knowledge/Other.md', note('other', 'Other'))['changes']
        actual_atomic = orbit.atomic
        def fail(path, data):
            if str(path).endswith('Other.md'): raise OSError('Simulated interruption')
            return actual_atomic(path, data)
        with patch.object(orbit, 'atomic', fail), self.assertRaises(OSError):
            orbit.apply(self.root, batch)
        pending = orbit.doctor(self.root)['pending_operations']
        self.assertEqual(len(pending), 1)
        with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan('Knowledge/Third.md', note('third', 'Third')))
        orbit.recover(self.root, pending[0])
        self.assertTrue((self.root / 'Knowledge/Other.md').exists())
        self.assertFalse(orbit.doctor(self.root)['pending_operations'])

    def test_recovery_refuses_human_edits_and_rollback_restores(self):
        orbit.apply(self.root, plan())
        p = self.root / 'Knowledge/Atlas.md'; original = p.read_text()
        opid = '00000000-0000-0000-0000-000000000001'
        record = {'id': opid, 'status': 'prepared', 'writes': [{'path': 'Knowledge/Atlas.md', 'before': original, 'after': note(body='Changed')} ]}
        orbit.atomic(self.root / '.orbit/operations' / (opid + '.json'), orbit.encode(record))
        p.write_text('human edit')
        with self.assertRaises(orbit.OrbitError): orbit.recover(self.root, opid)
        self.assertEqual(p.read_text(), 'human edit')
        p.write_text(record['writes'][0]['after'])
        orbit.recover(self.root, opid, rollback=True)
        self.assertEqual(p.read_text(), original)

    def test_active_lock_is_respected(self):
        with orbit.lock(self.root):
            with self.assertRaises(orbit.OrbitError): orbit.apply(self.root, plan())
        self.assertFalse((self.root / '.orbit/write.lock').exists())

    def test_cli_in_fresh_process_outside_vault(self):
        orbit.apply(self.root, plan())
        command = [sys.executable, str(Path(orbit.__file__)), 'search', 'staged rollout']
        result = subprocess.run(command, cwd=self.base, env=os.environ.copy(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['results'][0]['title'], 'Atlas')

    def test_read_windows_and_fenced_links(self):
        text = note(body='Real note.\n```md\n[[Not a real link]]\n```')
        orbit.apply(self.root, plan(content=text))
        result = orbit.read(self.root, 'Knowledge/Atlas.md', start=2, count=3)
        self.assertEqual([x['line'] for x in result['lines']], [2, 3, 4])
        self.assertTrue(result['more'])

if __name__ == '__main__': unittest.main()
