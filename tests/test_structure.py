import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import structure


def note(path, kind='concept', **fields):
    meta = {'id': 'example', 'title': 'Example', 'type': kind, 'summary': 'A useful fact.', **fields}
    text = '---\n' + '\n'.join(f'{key}: {json.dumps(value)}' for key, value in meta.items()) + '\n---\n# Example\n'
    return {'path': path, 'text': text, 'meta': meta}


class StructureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def schema(self, **fields):
        schema = note('Schemas/Custom.md', 'schema', schema_for='concept', schema_version=1,
                      required_fields=['id', 'title', 'type', 'summary', 'verified'],
                      required_sections=['Evidence'], validation='warn', **fields)
        return schema

    def write(self, entry):
        path = self.root / entry['path']
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(entry['text'])

    def test_bootstrap_returns_valid_schema_notes_without_writing(self):
        templates = structure.bootstrap(self.root)
        self.assertEqual(len(templates), 7)
        self.assertEqual(list(self.root.iterdir()), [])
        for path, text in templates.items():
            self.write({'path': path, 'text': text})
        self.assertEqual(structure.bootstrap(self.root), {})
        result = structure.check(self.root)
        self.assertEqual(result['data_format'], 2)
        self.assertEqual(len(result['definitions']), 7)
        self.assertEqual(result['warnings'], [])

    def test_existing_concepts_do_not_require_new_metadata(self):
        self.assertEqual(structure.schema_warnings(self.root, [note('Knowledge/Idea.md')]), [])

    def test_session_reports_resume_fields_and_sections(self):
        findings = structure.schema_warnings(self.root, [note('Projects/Example/Sessions/Start.md', 'session')])
        messages = [f['message'] for f in findings]
        self.assertIn('Missing required field: project', messages)
        self.assertIn('Missing required field: observed', messages)
        self.assertIn('Missing required section: Next actions', messages)
        self.assertTrue(all(f['severity'] == 'warning' for f in findings))
        session = note('Projects/Example/Sessions/Start.md', 'session', project='example', observed='2026-10-07')
        session['text'] += '\n'.join('## ' + h for h in ['Objective', 'Outcomes', 'Open questions', 'Next actions', 'Connections'])
        self.assertEqual(structure.schema_warnings(self.root, [session]), [])

    def test_custom_schema_overrides_bundled_default(self):
        self.write(self.schema())
        self.assertNotIn('Schemas/Concept.md', structure.bootstrap(self.root))
        findings = structure.schema_warnings(self.root, [note('Knowledge/Idea.md')])
        self.assertEqual(len(findings), 2)
        self.assertTrue(all(f['schema'] == 'Schemas/Custom.md' for f in findings))

    def test_proposed_schema_replaces_disk_before_validation(self):
        self.write(self.schema())
        replacement = self.schema()
        replacement['text'] = replacement['text'].replace('"warn"', '"strict"')
        findings = structure.schema_warnings(self.root, [replacement, note('Knowledge/Idea.md')])
        self.assertEqual(len(findings), 2)
        self.assertTrue(all(f['severity'] == 'error' for f in findings))

    def test_duplicate_schemas_and_malformed_schema_are_errors(self):
        schema = self.schema()
        duplicate = {**schema, 'path': 'Schemas/Duplicate.md'}
        findings = structure.schema_warnings(self.root, [schema, duplicate])
        self.assertEqual(len(findings), 2)
        self.assertTrue(all('Duplicate schema_for' in f['message'] and f['severity'] == 'error' for f in findings))
        malformed = {**schema, 'text': schema['text'].replace('schema_version: 1', 'schema_version: true')}
        findings = structure.schema_warnings(self.root, [malformed])
        self.assertTrue(any('positive integer' in f['message'] for f in findings))

    def test_fenced_example_heading_does_not_satisfy_schema(self):
        self.write(self.schema())
        concept = note('Knowledge/Idea.md', verified=True)
        concept['text'] += '\n````markdown\n## Evidence\n```\n## Evidence\n````\n'
        findings = structure.schema_warnings(self.root, [concept])
        self.assertEqual([f['message'] for f in findings], ['Missing required section: Evidence'])
        concept['text'] += '\n## Evidence\nA verified source.\n'
        self.assertEqual(structure.schema_warnings(self.root, [concept]), [])

    def test_declared_version_is_checked_and_inspection_does_not_write(self):
        self.write(note('Knowledge/Idea.md', schema_version=9))
        original = (self.root / 'Knowledge/Idea.md').read_bytes()
        result = structure.check(self.root, 'concept')
        self.assertEqual(set(result['definitions']), {'concept'})
        self.assertEqual(result['warnings'][0]['message'], 'schema_version must match 1')
        self.assertEqual((self.root / 'Knowledge/Idea.md').read_bytes(), original)

    def test_schema_symlink_cannot_read_outside_vault(self):
        with tempfile.TemporaryDirectory() as outside:
            (self.root / 'Schemas').symlink_to(outside)
            with self.assertRaises(orbit.OrbitError):
                structure.check(self.root)


if __name__ == '__main__':
    unittest.main()
