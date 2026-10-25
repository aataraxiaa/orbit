import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import formatting
import orbit
import test_mcp
from test_orbit import setup_legacy
from test_mcp import call


class FormattingTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.root = self.base / 'notes'
        self.root.mkdir()
        (self.root / 'plain.md').write_bytes(b'# Existing notes\n')
        env = patch.dict(os.environ, {'ORBIT_STATE': str(self.base / 'state'), 'ORBIT_CONFIG': str(self.base / 'config.json'), 'ORBIT_CACHE': str(self.base / 'cache')})
        env.start()
        self.addCleanup(env.stop)
        orbit.setup(str(self.root), 'Test')

    def plan(self, raw=None, path='plain.md', metadata=None):
        target = self.root / path
        if raw is not None:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        return {'changes': [{'path': path, 'expected_sha256': orbit.digest(target.read_bytes()),
                             'metadata': metadata if metadata is not None else {'title': 'Existing notes', 'type': 'concept', 'summary': 'Notes already written.'}}]}

    def format(self, plan, dry_run=True):
        return orbit.dispatch('format', {'orbit': 'Test', 'plan': plan, 'dry_run': dry_run})

    def test_body_bytes_preview_stable_ids_and_noop(self):
        bodies = [b'', b'# Plain', b'# Plain\r\n\r\nBody\r\n', b'# Mixed\r\nA\nB\rC', b'\xef\xbb\xbf# BOM\n']
        marker = (self.root / '.orbit/vault.json').read_bytes()
        asset = self.root / 'Sources/assets/original.bin'
        asset.parent.mkdir(parents=True)
        asset.write_bytes(b'\x00\xfforiginal')
        for raw in bodies:
            with self.subTest(raw=raw):
                plan = self.plan(raw)
                preview = self.format(plan)
                self.assertEqual((self.root / 'plain.md').read_bytes(), raw)
                receipt = preview['formatted'][0]
                self.assertEqual(receipt['before_sha256'], orbit.digest(raw))
                self.assertEqual(receipt['body_sha256'], orbit.digest(raw.removeprefix(b'\xef\xbb\xbf')))
                saved = self.format(plan, False)
                self.assertEqual(saved['formatted'], preview['formatted'])
                output = (self.root / 'plain.md').read_bytes()
                self.assertEqual(orbit.digest(output), receipt['after_sha256'])
                self.assertEqual(output.startswith(b'\xef\xbb\xbf'), raw.startswith(b'\xef\xbb\xbf'))
                self.assertTrue(output.endswith(raw.removeprefix(b'\xef\xbb\xbf')))
                rerun = self.format(self.plan(metadata={}), False)
                self.assertEqual(rerun['status'], 'unchanged')
                self.assertEqual(rerun['formatted'][0]['added'], {})
                self.assertEqual((self.root / 'plain.md').read_bytes(), output)
        self.assertEqual((self.root / '.orbit/vault.json').read_bytes(), marker)
        self.assertEqual(asset.read_bytes(), b'\x00\xfforiginal')

    def test_preserves_custom_blocks_existing_fields_and_header_endings(self):
        header = b'---\r\nid: stable-user-id\ncustom:\r\n  nested:\n    - one\r\n    - two\ntext: |\r\n  many lines\n  title: is opaque\r\nlist:\n  - nested: value\r\n---'
        raw = b'\xef\xbb\xbf' + header + b'\r\n# Body\nNo final newline'
        saved = self.format(self.plan(raw), False)
        output = (self.root / 'plain.md').read_bytes()
        self.assertIn(header[len(b'---\r\n'):], output)
        self.assertEqual(orbit.metadata(output.decode())['id'], 'stable-user-id')
        self.assertNotIn('id', saved['formatted'][0]['added'])
        self.assertEqual(formatting.header(output)[2], '# Body\nNo final newline')

    def test_rejects_ambiguous_metadata_and_leaves_bytes(self):
        invalid = [b'---\ntitle: x', b'---', b'--- \ntitle: x\n---\n',
                   b'---\ntitle: []\n---\n', b'---\nid: null\n---\n', b'---\nsummary: |\n  text\n---\n',
                   b'---\ncustom: x\ncustom: y\n---\n', b'---\ntitle: x\n  continuation\n---\n',
                   b'---\n"title": x\n---\n', b'---\ntitle: false\n---\n', b'---\nid: 123\n---\n',
                   b'---\ntitle: "broken\n---\n', b'---\ntitle: [broken\n---\n',
                   b'---\ntitle: \n---\n', b'---\ntitle: x # inline comment\n---\n']
        for raw in invalid:
            with self.subTest(raw=raw), self.assertRaises(orbit.OrbitError):
                self.format(self.plan(raw), False)
            self.assertEqual((self.root / 'plain.md').read_bytes(), raw)

    def test_all_line_separators_refuse_without_writes(self):
        for separator in ('\n', '\r', '\v', '\f', '\x1c', '\x1d', '\x1e', '\x85', '\u2028', '\u2029'):
            for field in ('title', 'type', 'summary'):
                with self.subTest(separator=repr(separator), field=field):
                    raw = b'# Original content\n'
                    plan = self.plan(raw)
                    plan['changes'][0]['metadata'][field] = 'Alpha' + separator + 'Beta'
                    with self.assertRaisesRegex(orbit.OrbitError, 'single-line'):
                        self.format(plan, False)
                    self.assertEqual((self.root / 'plain.md').read_bytes(), raw)
            for field in ('id', 'title', 'type', 'summary'):
                with self.subTest(existing=field, separator=repr(separator)):
                    raw = ('---\n' + field + ': ' + json.dumps('Alpha' + separator + 'Beta') + '\n---\nBody').encode()
                    with self.assertRaisesRegex(orbit.OrbitError, 'single-line'):
                        self.format(self.plan(raw), False)
                    self.assertEqual((self.root / 'plain.md').read_bytes(), raw)

    def test_conflicts_unsafe_targets_and_existing_values(self):
        plan = self.plan()
        (self.root / 'plain.md').write_bytes(b'Human edit')
        with self.assertRaisesRegex(orbit.OrbitError, 'conflict'):
            self.format(plan, False)
        for path in ('../outside.md', '/outside.md', 'ORBIT.md', '.orbit/private.md', 'Sources/assets/original.md', './plain.md', 'plain.txt'):
            with self.subTest(path=path), self.assertRaises(orbit.OrbitError):
                self.format({'changes': [dict(plan['changes'][0], path=path)]}, False)
        (self.root / 'linked.md').symlink_to(self.root / 'plain.md')
        with self.assertRaisesRegex(orbit.OrbitError, 'Symlink'):
            self.format({'changes': [dict(plan['changes'][0], path='linked.md')]})
        self.format(self.plan(), False)
        with self.assertRaisesRegex(orbit.OrbitError, 'preserve existing title'):
            self.format(self.plan(metadata={'title': 'Overwrite'}), False)
        with self.assertRaisesRegex(orbit.OrbitError, 'only title'):
            self.format(self.plan(metadata={'id': 'replace'}), False)
        duplicate = self.plan()
        duplicate['changes'] *= 2
        with self.assertRaisesRegex(orbit.OrbitError, 'Duplicate target'):
            self.format(duplicate)

    def test_existing_links_warn_but_apply_remains_strict(self):
        raw = b'# Existing notes\n[[missing]] [[plain#Absent]]\n'
        result = self.format(self.plan(raw), False)
        warnings = [w for w in result['warnings'] if w.get('preserved')]
        self.assertEqual({w['kind'] for w in warnings}, {'unresolved-link', 'unresolved-anchor'})
        current = (self.root / 'plain.md').read_bytes()
        with self.assertRaisesRegex(orbit.OrbitError, 'Resolve links'):
            orbit.apply(self.root, {'changes': [{'path': 'plain.md', 'content': current.decode(),
                         'expected_sha256': orbit.digest(current), 'reason': 'ordinary save'}]})

    def test_new_ambiguity_elsewhere_and_duplicate_ids_refuse(self):
        (self.root / 'other.md').write_bytes(b'# Existing notes\n')
        (self.root / 'ref.md').write_bytes(b'[[Existing notes]]\n')
        plan = self.plan(b'# Different heading\n')
        with self.assertRaisesRegex(orbit.OrbitError, 'ambiguous-link'):
            self.format(plan, False)
        (self.root / 'ref.md').unlink()
        (self.root / 'other.md').write_bytes(b'---\nid: duplicate\n---\n')
        with self.assertRaisesRegex(orbit.OrbitError, 'duplicate-id'):
            self.format(self.plan(b'---\nid: duplicate\n---\n'), False)

    def test_strict_schemas_still_block_and_format2_marker_unchanged(self):
        new = self.base / 'format2'
        setup_legacy(new, 'Modern')
        marker = (new / '.orbit/vault.json').read_bytes()
        schema = new / 'Schemas/Concept.md'
        text = schema.read_text().replace('validation: "warn"', 'validation: "strict"').replace('required_sections: []', 'required_sections: ["Evidence"]')
        schema.write_text(text)
        (new / 'draft.md').write_bytes(b'Incomplete concept')
        args = {'orbit': 'Modern', 'plan': {'changes': [{'path': 'draft.md', 'expected_sha256': orbit.digest(b'Incomplete concept'),
                    'metadata': {'title': 'Draft', 'type': 'concept', 'summary': 'Draft concept'}}]}, 'dry_run': False}
        with self.assertRaisesRegex(orbit.OrbitError, 'Schema validation failed'):
            orbit.dispatch('format', args)
        self.assertEqual((new / 'draft.md').read_bytes(), b'Incomplete concept')
        self.assertEqual((new / '.orbit/vault.json').read_bytes(), marker)

    def test_interrupted_resume_rollback_and_human_edit_refusal(self):
        original_atomic = orbit.atomic
        for resolution in ('resume', 'rollback', 'human'):
            with self.subTest(resolution=resolution):
                plan = self.plan(b'\xef\xbb\xbf# Original\r\n')
                plan['changes'] += self.plan(b'# Second\n', 'second.md')['changes']
                before = {c['path']: (self.root / c['path']).read_bytes() for c in plan['changes']}
                def interrupt(path, data):
                    if path == self.root / 'second.md':
                        raise OSError('simulated interruption')
                    return original_atomic(path, data)
                with patch.object(orbit, 'atomic', side_effect=interrupt), self.assertRaises(OSError):
                    self.format(plan, False)
                operations = [p for p in (self.root / '.orbit/operations').glob('*.json') if json.loads(p.read_text())['status'] == 'prepared']
                self.assertEqual(len(operations), 1)
                operation = operations[0].stem
                if resolution == 'human':
                    (self.root / 'plain.md').write_bytes(b'Human change')
                    snapshot = (self.root / 'second.md').read_bytes()
                    with self.assertRaises(orbit.OrbitError):
                        orbit.recover(self.root, operation)
                    self.assertEqual((self.root / 'plain.md').read_bytes(), b'Human change')
                    self.assertEqual((self.root / 'second.md').read_bytes(), snapshot)
                else:
                    orbit.recover(self.root, operation, rollback=resolution == 'rollback')
                    for path, raw in before.items():
                        if resolution == 'rollback':
                            self.assertEqual((self.root / path).read_bytes(), raw)
                        else:
                            self.assertTrue((self.root / path).read_bytes().endswith(raw.removeprefix(b'\xef\xbb\xbf')))
                            self.assertEqual(orbit.metadata((self.root / path).read_text())['title'], 'Existing notes')


class FormatMCPTest(unittest.TestCase):
    setUp = test_mcp.MCPTest.setUp
    run_server = test_mcp.MCPTest.run_server
    result = test_mcp.MCPTest.result
    setup_vault = test_mcp.MCPTest.setup_vault

    def test_named_format_default_preview_and_fresh_process_readback(self):
        self.setup_vault()
        work = self.base / 'work'
        self.result(self.run_server([call(1, 'setup', {'path': str(work), 'name': 'Work', 'create': True})])[0])
        for root, body in ((self.vault, b'Personal content\r\n'), (work, b'Work content\n')):
            (root / 'existing.md').write_bytes(body)
        body = (work / 'existing.md').read_bytes()
        plan = {'changes': [{'path': 'existing.md', 'expected_sha256': orbit.digest(body),
                            'metadata': {'title': 'Work content', 'type': 'concept', 'summary': 'Work content'}}]}
        synced = self.result(self.run_server([call(1, 'sync', {'orbit': 'Work'})])[0])
        history = self.result(self.run_server([call(1, 'sync', {'orbit': 'Work', 'action': 'history', 'path': 'existing.md'})])[0])
        plan['changes'][0]['observations'] = [o['id'] for o in history['observations']]
        plan['changes'][0]['expected_heads'] = synced['heads'].get('existing.md', [])
        args = {'orbit': 'Work', 'plan': plan}
        preview = self.result(self.run_server([call(1, 'format', args)])[0])
        self.assertEqual(preview['status'], 'preview')
        self.assertEqual((work / 'existing.md').read_bytes(), body)
        committed = self.result(self.run_server([call(1, 'format', dict(args, dry_run=False))])[0])
        read = self.result(self.run_server([call(1, 'read', {'orbit': 'Work', 'path': 'existing.md'})])[0])
        self.assertEqual(read['sha256'], committed['formatted'][0]['after_sha256'])
        self.assertEqual(committed['target']['name'], 'Work')
        self.assertEqual((self.vault / 'existing.md').read_bytes(), b'Personal content\r\n')
        bad = dict(args, preserved_link_issues=[])
        self.assertIn('error', self.run_server([call(1, 'format', bad)])[0])
