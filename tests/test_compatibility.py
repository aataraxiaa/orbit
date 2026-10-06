import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import orbit
import knowledge
import retrieval
from test_orbit import plan


class CompatibilityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'vault'
        env = patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'config.json'),
                                    'ORBIT_CACHE': str(self.base / 'cache')}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        orbit.setup(str(self.root), create=True)

    def make_legacy(self):
        (self.root / '.orbit').rename(self.root / '.second-brain')
        (self.root / 'ORBIT.md').rename(self.root / 'SECOND_BRAIN.md')

    def test_legacy_identity_rules_journals_search_and_capture_survive(self):
        self.make_legacy()
        marker = (self.root / '.second-brain/vault.json').read_bytes()
        rules = self.root / 'SECOND_BRAIN.md'
        rules.write_text('# Custom rules\nKeep my content.\n')
        orbit.setup(str(self.root))
        self.assertEqual((self.root / '.second-brain/vault.json').read_bytes(), marker)
        self.assertEqual(rules.read_text(), '# Custom rules\nKeep my content.\n')
        receipt = orbit.apply(self.root, plan())
        journal = self.root / '.second-brain/operations' / (receipt['operation'] + '.json')
        self.assertEqual(json.loads(journal.read_text())['status'], 'committed')
        self.assertEqual(orbit.search(self.root, 'staged deployment')['results'][0]['path'], 'Knowledge/Atlas.md')
        source = self.base / 'source.txt'
        source.write_text('A retained source')
        orbit.capture(self.root, str(source))
        self.assertTrue(list((self.root / '.second-brain/integrations').glob('*.json')))
        self.assertEqual(knowledge.catalog(self.root)['total'], 1)
        self.assertFalse((self.root / '.orbit').exists())
        self.assertFalse((self.root / 'ORBIT.md').exists())

    def test_legacy_lock_and_pending_operation_block_writes(self):
        self.make_legacy()
        with orbit.lock(self.root):
            self.assertTrue((self.root / '.second-brain/write.lock').is_file())
            with self.assertRaisesRegex(orbit.OrbitError, 'write lock'):
                orbit.apply(self.root, plan())
        operations = self.root / '.second-brain/operations'
        operations.mkdir()
        (operations / 'pending.json').write_text(json.dumps({'status': 'prepared', 'id': 'pending'}))
        self.assertEqual(orbit.doctor(self.root)['pending_operations'], ['pending'])
        with self.assertRaisesRegex(orbit.OrbitError, 'pending operation'):
            orbit.apply(self.root, plan())

    def test_dual_state_and_rules_refuse_setup(self):
        (self.root / '.second-brain').mkdir()
        with self.assertRaisesRegex(orbit.OrbitError, 'Both .orbit'):
            orbit.setup(str(self.root))
        (self.root / '.second-brain').rmdir()
        (self.root / 'SECOND_BRAIN.md').write_text('conflicting rules')
        with self.assertRaisesRegex(orbit.OrbitError, 'conflicting vault rules'):
            orbit.setup(str(self.root))

    def test_default_config_fallback_and_explicit_precedence(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, 'home', return_value=self.base):
            old = self.base / '.config/second-brain/config.json'
            new = self.base / '.config/orbit/config.json'
            self.assertEqual(orbit.config_path(), new)
            old.parent.mkdir(parents=True)
            old.write_text('{}')
            self.assertEqual(orbit.config_path(), old)
            new.parent.mkdir(parents=True)
            new.write_text('{}')
            self.assertEqual(orbit.config_path(), new)
            with patch.dict(os.environ, {'SECOND_BRAIN_CONFIG': 'legacy.json'}):
                self.assertEqual(orbit.config_path(), Path('legacy.json'))
                with patch.dict(os.environ, {'ORBIT_CONFIG': 'explicit.json'}):
                    self.assertEqual(orbit.config_path(), Path('explicit.json'))

    def test_legacy_state_cannot_be_read_as_notes(self):
        self.make_legacy()
        (self.root / '.second-brain/private.md').write_text('journal content')
        with self.assertRaises(orbit.OrbitError):
            orbit.read(self.root, '.second-brain/private.md')

    def test_legacy_cache_override_and_new_precedence(self):
        os.environ.pop('ORBIT_CACHE')
        os.environ['SECOND_BRAIN_CACHE'] = str(self.base / 'old-cache')
        self.assertEqual(retrieval.cache_path(self.root).parent, self.base / 'old-cache')
        os.environ['ORBIT_CACHE'] = str(self.base / 'new-cache')
        self.assertEqual(retrieval.cache_path(self.root).parent, self.base / 'new-cache')
