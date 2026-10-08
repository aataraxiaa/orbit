import json
import os
import sqlite3
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import retrieval


class RetrievalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / 'vault'
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'config.json'), 'ORBIT_CACHE': str(self.base / 'cache')})
        self.env.start()
        orbit.setup(str(self.root), create=True)

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def write(self, path, body, project='alpha'):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('---\nid: ' + json.dumps(path) + '\ntitle: Example\nproject: ' + project + '\n---\n# Decision\n' + body)
        return target

    def test_incremental_edit_delete_and_rename(self):
        path = self.write('Knowledge/a.md', 'rollback reversible')
        first = retrieval.search(self.root, 'rollback')
        self.assertEqual(first['results'][0]['path'], 'Knowledge/a.md')
        self.assertEqual(retrieval.refresh(self.root)['reparsed'], 0)
        path.write_text(path.read_text().replace('rollback', 'rollover'))
        self.assertEqual(retrieval.search(self.root, 'rollback')['total'], 0)
        self.assertEqual(retrieval.search(self.root, 'rollover')['total'], 1)
        path.rename(path.with_name('b.md'))
        self.assertEqual(retrieval.search(self.root, 'rollover')['results'][0]['path'], 'Knowledge/b.md')
        path.with_name('b.md').unlink()
        self.assertEqual(retrieval.search(self.root, 'rollover')['total'], 0)

    def test_typed_sessions_summary_search_and_rebuild(self):
        for path, kind, state in [('Projects/Atlas/Sessions/Review.md', 'session', 'archived'),
                                  ('Projects/Atlas/Decisions/Rollout.md', 'decision', 'current')]:
            target = self.write(path, 'Details and qualifications.', 'atlas')
            target.write_text(target.read_text().replace('project: atlas',
                f'project: atlas\ntype: {kind}\nstatus: {state}\nsummary: zephyr deployment\nschema_version: 1\nobserved: 2026-10-07'))
        session = retrieval.search(self.root, 'zephyr', note_type='session')['results']
        self.assertEqual([n['path'] for n in session], ['Projects/Atlas/Sessions/Review.md'])
        self.assertEqual(session[0]['type'], 'session')
        self.assertEqual(session[0]['observed'], '2026-10-07')
        self.assertEqual(retrieval.search(self.root, 'zephyr', status='current')['results'][0]['type'], 'decision')
        self.assertEqual(retrieval.catalog(self.root, note_type='session')['total'], 1)
        self.assertEqual(retrieval.catalog(self.root, scope='Projects/Atlas', status='current')['total'], 1)
        self.assertEqual(retrieval.refresh(self.root)['reparsed'], 0)
        retrieval.refresh(self.root, rebuild=True)
        self.assertEqual(retrieval.search(self.root, 'zephyr', note_type='session')['results'][0]['sha256'], session[0]['sha256'])

    def test_schema_notes_require_explicit_type_filter(self):
        target = self.write('Schemas/Test.md', 'oranges')
        target.write_text(target.read_text().replace('project: alpha', 'project: alpha\ntype: schema'))
        self.assertEqual(retrieval.search(self.root, 'oranges')['total'], 0)
        self.assertEqual(retrieval.search(self.root, 'oranges', note_type='schema')['total'], 1)
        self.assertEqual(retrieval.catalog(self.root)['total'], 0)

    def test_same_size_preserved_mtime_edit_is_found(self):
        path = self.write('a.md', 'before')
        retrieval.refresh(self.root)
        stat = path.stat()
        path.write_text(path.read_text().replace('before', 'afterx'))
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.assertEqual(retrieval.search(self.root, 'afterx')['total'], 1)

    def test_scope_filters_before_limit(self):
        self.write('One/a.md', 'deployment', 'alpha')
        self.write('Two/b.md', 'deployment', 'beta')
        self.assertEqual(retrieval.search(self.root, 'deployment', scope='beta')['total'], 1)
        self.assertEqual(retrieval.search(self.root, 'deployment', scope='One')['results'][0]['path'], 'One/a.md')
        self.assertEqual(retrieval.search(self.root, 'deployment', scope='alp')['total'], 0)

    def test_corruption_rebuild_and_rebuild_preserve_notes(self):
        path = self.write('a.md', 'needle')
        original = path.read_bytes()
        result = retrieval.refresh(self.root)
        Path(result['cache']).write_bytes(b'corrupt')
        self.assertEqual(retrieval.search(self.root, 'needle')['total'], 1)
        retrieval.refresh(self.root, rebuild=True)
        self.assertEqual(path.read_bytes(), original)

    def test_fences_are_not_headings_and_output_is_bounded(self):
        body = '# Real\ncondition applies\n```python\n# not heading\n' + ('needle = 1\n' * 1800) + '```\nOnly if approved.\n'
        chunks = list(retrieval.passages(body))
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0][2], 'Real')
        self.write('a.md', body)
        result = retrieval.search(self.root, 'needle')
        self.assertTrue(result['coverage']['truncated'])
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, indent=2)), 12000)

    def test_original_assets_and_symlinks_excluded(self):
        self.write('Sources/assets/raw.md', 'needle')
        self.write('a.md', 'needle')
        (self.root / 'linked.md').symlink_to(self.root / 'a.md')
        self.assertEqual(retrieval.search(self.root, 'needle')['total'], 1)

    def test_evidence_changed_after_inventory_is_refreshed(self):
        path = self.write('a.md', 'needle old')
        original_refresh = retrieval.refresh
        calls = []
        def change_after_refresh(root, rebuild=False):
            result = original_refresh(root, rebuild)
            if not calls:
                path.write_text(path.read_text().replace('old', 'new'))
            calls.append(rebuild)
            return result
        with patch.object(retrieval, 'refresh', side_effect=change_after_refresh):
            result = retrieval.search(self.root, 'needle')
        self.assertEqual(calls, [False, True])
        self.assertEqual(result['results'][0]['sha256'], orbit.digest(path.read_bytes()))
        self.assertTrue(any('new' in line['text'] for line in result['results'][0]['snippets']))

    def test_rejects_cache_in_vault_without_creating_it(self):
        cache = self.root / 'unwanted'
        with patch.dict(os.environ, {'ORBIT_CACHE': str(cache)}):
            with self.assertRaises(OSError):
                retrieval.refresh(self.root)
        self.assertFalse(cache.exists())

    def test_exact_alias_beats_repetition(self):
        path = self.write('a.md', 'staged rollout')
        path.write_text(path.read_text().replace('title: Example', 'title: Example\naliases: ["Launch sequence", "Other name"]'))
        self.write('log.md', 'launch sequence blah ' * 100)
        result = retrieval.search(self.root, 'Launch sequence')
        self.assertEqual(result['results'][0]['path'], 'a.md')

    def test_overview_accompanies_matching_detail(self):
        self.write('a.md', 'Only deploy with approval.\n\n## Implementation\nCoordinator deploys the service.\n')
        result = retrieval.search(self.root, 'Coordinator')
        text = '\n'.join(s['text'] for s in result['results'][0]['snippets'])
        self.assertIn('Only deploy with approval.', text)
        self.assertIn('Coordinator', text)

    def test_morphology_matches_without_domain_synonyms(self):
        self.write('a.md', 'Cache refreshed results for contacts. Retry safely.')
        for query in ('cached', 'refresh', 'contact', 'retried'):
            with self.subTest(query=query):
                result = retrieval.search(self.root, query)
                self.assertEqual(result['total'], 1)
                self.assertEqual(result['results'][0]['path'], 'a.md')

    def test_locked_cache_is_not_deleted(self):
        self.write('a.md', 'needle')
        cache = Path(retrieval.refresh(self.root)['cache'])
        inode = cache.stat().st_ino
        holder = sqlite3.connect(cache)
        holder.execute('BEGIN EXCLUSIVE')
        original_connect = retrieval.connect
        def brief_connect(path):
            db = original_connect(path)
            db.execute('PRAGMA busy_timeout=10')
            return db
        try:
            with patch.object(retrieval, 'connect', side_effect=brief_connect):
                with self.assertRaises(sqlite3.OperationalError):
                    retrieval.refresh(self.root)
            self.assertEqual(cache.stat().st_ino, inode)
        finally:
            holder.rollback()
            holder.close()
        self.assertEqual(retrieval.search(self.root, 'needle')['total'], 1)

    def test_cache_failure_propagates_and_does_not_edit_note(self):
        path = self.write('a.md', 'needle')
        original = path.read_bytes()
        with patch.object(retrieval, 'connect', side_effect=OSError('unavailable')):
            with self.assertRaises(OSError):
                retrieval.search(self.root, 'needle')
        self.assertEqual(path.read_bytes(), original)

    def test_unknown_database_error_preserves_cache(self):
        self.write('a.md', 'needle')
        cache = Path(retrieval.refresh(self.root)['cache'])
        original = cache.read_bytes()
        inode = cache.stat().st_ino
        for message in ('unknown database error', 'database disk image is malformed: unknown cause'):
            with self.subTest(message=message):
                error = sqlite3.DatabaseError(message)
                with patch.object(retrieval, 'connect', side_effect=error):
                    with self.assertRaises(sqlite3.DatabaseError) as raised:
                        retrieval.refresh(self.root)
                self.assertIs(raised.exception, error)
                self.assertEqual(cache.stat().st_ino, inode)
                self.assertEqual(cache.read_bytes(), original)
        self.assertEqual(retrieval.search(self.root, 'needle')['total'], 1)


if __name__ == '__main__':
    unittest.main()
