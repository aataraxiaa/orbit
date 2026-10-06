import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import knowledge
from test_orbit import note, plan


class KnowledgeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / 'vault'
        self.env = patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'config.json')})
        self.env.start()
        orbit.setup(str(self.root), create=True)

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def capture(self):
        source = self.base / 'source.txt'
        source.write_text('Staged deployment preserves rollback.')
        receipt = orbit.capture(self.root, str(source))
        return knowledge.init_capture(self.root, receipt)

    def advance(self, current, stage, **fields):
        if stage == 'extracted' and 'coverage' in fields and 'extraction' not in fields:
            path = 'Sources/Extract.md'
            if not (self.root / path).exists():
                orbit.apply(self.root, plan(path, note('extraction', 'Extract', 'Original source transcript.')))
            fields['extraction'] = [{'path': path, 'sha256': orbit.read(self.root, path)['sha256']}]
        return knowledge.integration(self.root, dict(source_sha256=current['source_sha256'], expected_version=current['version'], stage=stage, **fields))

    def integrated(self):
        current = self.capture()
        current = self.advance(current, 'extracted', coverage={'status': 'partial', 'description': 'First paragraph only'}, deferred=['Read appendix'])
        saved = orbit.apply(self.root, plan())
        current = self.advance(current, 'integrated', notes=[{'path': 'Knowledge/Atlas.md', 'sha256': orbit.read(self.root, 'Knowledge/Atlas.md')['sha256']}], operation=saved['operation'])
        return current

    def test_capture_deduplicates_without_regressing_progress(self):
        first = self.capture()
        progressed = self.advance(first, 'extracted', coverage={'status': 'full', 'description': 'All source text read'})
        self.assertEqual(self.capture(), progressed)
        self.assertEqual(knowledge.integration(self.root)['total'], 1)
        with self.assertRaises(orbit.OrbitError):
            self.advance(first, 'extracted', coverage={'status': 'partial', 'description': 'Other writer'})
        self.assertEqual(self.advance(first, 'extracted', coverage=progressed['coverage']), progressed)

    def test_stages_require_coverage_and_committed_evidence(self):
        first = self.capture()
        with self.assertRaises(orbit.OrbitError): self.advance(first, 'verified')
        with self.assertRaises(orbit.OrbitError): self.advance(first, 'extracted')
        current = self.advance(first, 'extracted', coverage={'status': 'full', 'description': 'Read entire source'})
        with self.assertRaises(orbit.OrbitError): self.advance(current, 'integrated')
        with self.assertRaises(orbit.OrbitError): self.advance(current, 'captured')

    def test_verification_runs_search_and_preserves_partial_coverage(self):
        current = self.integrated()
        with self.assertRaises(orbit.OrbitError):
            self.advance(current, 'verified', verification=[{'query': 'unfindableterm', 'paths': ['Knowledge/Atlas.md']}])
        verified = self.advance(current, 'verified', verification=[{'query': 'staged deployment', 'paths': ['Knowledge/Atlas.md']}])
        self.assertEqual(verified['stage'], 'verified')
        self.assertEqual(verified['coverage']['status'], 'partial')
        flags = knowledge.maintain(self.root)['candidates']
        self.assertIn('incomplete-integration', [f['kind'] for f in flags])

    def test_changed_note_blocks_verification_and_flags_maintenance(self):
        current = self.integrated()
        path = self.root / 'Knowledge/Atlas.md'
        path.write_text(path.read_text() + '\nManual edit\n')
        with self.assertRaises(orbit.OrbitError):
            self.advance(current, 'verified', verification=[{'query': 'staged', 'paths': ['Knowledge/Atlas.md']}])
        self.assertIn('integration-evidence-changed', [f['kind'] for f in knowledge.maintain(self.root)['candidates']])

    def test_maintenance_detects_extraction_changes_after_verification(self):
        current = self.integrated()
        self.advance(current, 'verified', coverage={'status': 'full', 'description': 'All source text'}, deferred=[], verification=[{'query': 'staged deployment', 'paths': ['Knowledge/Atlas.md']}])
        self.assertEqual(knowledge.maintain(self.root)['candidates'], [])
        path = self.root / 'Sources/Extract.md'
        path.write_text(path.read_text() + '\nCorrected source detail.\n')
        flags = knowledge.maintain(self.root)['candidates']
        self.assertTrue(any(flag['kind'] == 'integration-evidence-changed' and flag['path'] == 'Sources/Extract.md' and flag['evidence_role'] == 'extraction' for flag in flags))
        path.unlink()
        self.assertTrue(any(flag.get('evidence_role') == 'extraction' for flag in knowledge.maintain(self.root)['candidates']))

    def test_source_tampering_and_active_lock_are_rejected(self):
        current = self.capture()
        with orbit.lock(self.root):
            with self.assertRaises(orbit.OrbitError): self.advance(current, 'extracted')
        (self.root / current['source_path']).write_text('changed')
        with self.assertRaises(orbit.OrbitError): self.advance(current, 'extracted')

    def test_catalog_scope_maps_and_relations_are_readonly(self):
        original = note(body='- supports [[Knowledge/Other]] — asserted: Rollback was tested.\n- related-to [[Knowledge/Other]] — inferred: Shared constraints.\n```md\n- contradicts [[Knowledge/Other]] — asserted: Example only.\n```\nOrdinary [[Knowledge/Other]] link.')
        original = original.replace('---\n#', 'project: "atlas"\ntopics: ["delivery"]\n---\n#')
        batch = plan(content=original)
        batch['changes'] += plan('Knowledge/Other.md', note('other', 'Other'))['changes']
        orbit.apply(self.root, batch)
        before = {p: p.read_bytes() for p in self.root.rglob('*.md')}
        catalog = knowledge.catalog(self.root, scope='delivery')
        self.assertEqual(catalog['total'], 1)
        self.assertIn('Knowledge/Atlas.md', catalog['markdown'])
        relations = knowledge.relations(self.root, 'Other')['relations']
        self.assertEqual(len(relations), 2)
        self.assertEqual(relations[0]['target'], 'Knowledge/Other.md')
        self.assertEqual(relations[1]['basis'], 'inferred')
        self.assertGreater(relations[0]['line'], 1)
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*.md')})
        with self.assertRaises(orbit.OrbitError): knowledge.relations(self.root, 'Unknown')

    def test_extraction_requires_live_saved_evidence(self):
        first = self.capture()
        with self.assertRaises(orbit.OrbitError):
            self.advance(first, 'extracted', coverage={'status': 'full', 'description': 'All text'}, extraction=[])
        current = self.advance(first, 'extracted', coverage={'status': 'full', 'description': 'All text'})
        (self.root / 'Sources/Extract.md').write_text('External edit')
        with self.assertRaises(orbit.OrbitError):
            knowledge.integration(self.root, {'source_sha256': current['source_sha256'], 'expected_version': current['version'], 'stage': 'extracted'})

    def test_multi_operation_integration(self):
        current = self.capture()
        current = self.advance(current, 'extracted', coverage={'status': 'full', 'description': 'All text'})
        one = orbit.apply(self.root, plan())
        two = orbit.apply(self.root, plan('Knowledge/Other.md', note('other', 'Other', 'Staged rollout in Other.')))
        paths = ['Knowledge/Atlas.md', 'Knowledge/Other.md']
        current = self.advance(current, 'integrated', operations=[one['operation'], two['operation']], notes=[{'path': p, 'sha256': orbit.read(self.root, p)['sha256']} for p in paths])
        self.assertEqual(len(current['operations']), 2)
        self.assertEqual(self.advance(current, 'verified', verification=[{'query': 'staged rollout', 'paths': paths}])['stage'], 'verified')

    def test_legacy_relations_pagination_and_malformed_record(self):
        content = note(body='- applies_to [[Other]] — rollback requirement.\n- learned_from [[Other]] — source reasoning.\n## Possible connections\n- depends_on [[Other]] — inferred from shared constraints.')
        batch = plan(content=content)
        batch['changes'] += plan('Knowledge/Other.md', note('other', 'Other'))['changes']
        orbit.apply(self.root, batch)
        edges = knowledge.relations(self.root)['relations']
        self.assertEqual([edge['basis'] for edge in edges], ['recorded', 'recorded', 'inferred'])
        self.assertEqual([edge['type'] for edge in edges], ['applies_to', 'learned_from', 'depends_on'])
        first = knowledge.catalog(self.root, limit=1)
        second = knowledge.catalog(self.root, limit=1, offset=1)
        self.assertTrue(first['more'])
        self.assertFalse(second['more'])
        self.assertNotEqual(first['entries'][0]['path'], second['entries'][0]['path'])
        folder = self.root / '.orbit/integrations'
        folder.mkdir(exist_ok=True)
        (folder / 'broken.json').write_text('{bad json')
        self.assertEqual(knowledge.integration(self.root)['errors'][0]['kind'], 'malformed-integration')
        self.assertIn('malformed-integration', [f['kind'] for f in knowledge.maintain(self.root)['candidates']])

    def test_malformed_evidence_does_not_hide_other_maintenance(self):
        first = self.capture()
        source = self.base / 'other-source.txt'
        source.write_text('Different source')
        second = orbit.capture(self.root, str(source))['processing']
        path = self.root / '.orbit/integrations' / (first['source_sha256'] + '.json')
        for malformed in ({'path': '../escape.md', 'sha256': 'a' * 64}, {'path': '.orbit/private.md', 'sha256': 'a' * 64}, {'path': 'Knowledge/Atlas.md', 'sha256': 'invalid'}):
            with self.subTest(evidence=malformed):
                path.write_text(json.dumps(first | {'notes': [malformed]}))
                result = knowledge.maintain(self.root)
                self.assertIn('malformed-integration', [f['kind'] for f in result['candidates']])
                self.assertTrue(any(f.get('source_sha256') == second['source_sha256'] for f in result['candidates']))
                with self.assertRaises(orbit.OrbitError): self.advance(first, 'extracted')
        with self.assertRaises(orbit.OrbitError): knowledge.integration(self.root, [])

    def test_cli_source_to_map_integration(self):
        def cli(*args, payload=None):
            result = subprocess.run([sys.executable, str(Path(orbit.__file__)), '--vault', str(self.root), *args], input=json.dumps(payload) if payload else None, capture_output=True, text=True, env=os.environ.copy())
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        def transition(current, stage, **fields):
            request = dict(source_sha256=current['source_sha256'], expected_version=current['version'], stage=stage, **fields)
            path = self.base / 'integration-request.json'
            path.write_text(json.dumps(request))
            return cli('integration', str(path))

        source = self.base / 'planning.txt'
        source.write_text('Atlas deployment must remain reversible.')
        captured = cli('capture', str(source))
        source_path = 'Sources/Planning.md'
        source_note = note('planning', 'Planning', 'Atlas deployment must remain reversible.\nOriginal: [[' + captured['path'] + ']]')
        saved_source = cli('apply', '-', payload=plan(source_path, source_note))
        extraction = [{'path': source_path, 'sha256': cli('read', source_path)['sha256']}]
        current = transition(captured['processing'], 'extracted', coverage={'status': 'full', 'description': 'Entire one-line source retained'}, extraction=extraction)
        decision = note(body='Atlas deployment remains reversible.\n- learned_from [[Sources/Planning]] — original deployment constraint.')
        home = note('home', 'Home', 'Start with [[Knowledge/Atlas]] for deployment decisions.').replace('type: "project"', 'type: "map"')
        batch = plan(content=decision)
        batch['changes'] += plan('Maps/Home.md', home)['changes']
        saved = cli('apply', '-', payload=batch)
        paths = ['Knowledge/Atlas.md', 'Maps/Home.md']
        current = transition(current, 'integrated', operations=[saved_source['operation'], saved['operation']], notes=[{'path': p, 'sha256': cli('read', p)['sha256']} for p in paths])
        current = transition(current, 'verified', verification=[{'query': 'Atlas deployment', 'paths': ['Knowledge/Atlas.md']}, {'query': 'Home', 'paths': ['Maps/Home.md']}])
        self.assertEqual(current['stage'], 'verified')
        self.assertEqual(cli('capture', str(source))['processing'], current)
        self.assertEqual(cli('catalog', '--limit', '1')['entries'][0]['path'], 'Maps/Home.md')
        self.assertTrue(cli('catalog', '--limit', '1', '--offset', '1')['entries'])
        self.assertEqual(cli('relations', 'Atlas')['relations'][0]['target'], source_path)
        self.assertEqual(cli('maintain')['candidates'], [])

    def test_integrated_notes_must_belong_to_operation(self):
        current = self.capture()
        current = self.advance(current, 'extracted', coverage={'status': 'full', 'description': 'All text'})
        orbit.apply(self.root, plan())
        unrelated = orbit.apply(self.root, plan('Knowledge/Other.md', note('other', 'Other')))
        with self.assertRaises(orbit.OrbitError):
            self.advance(current, 'integrated', notes=[{'path': 'Knowledge/Atlas.md', 'sha256': orbit.read(self.root, 'Knowledge/Atlas.md')['sha256']}], operation=unrelated['operation'])


if __name__ == '__main__': unittest.main()
