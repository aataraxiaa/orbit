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
from test_orbit import setup_legacy
import knowledge
import retrieval
from test_orbit import plan


class CompatibilityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'vault'
        env = patch.dict(os.environ, {'ORBIT_STATE': str(self.base / 'state'), 'ORBIT_CONFIG': str(self.base / 'config.json'),
                                    'ORBIT_CACHE': str(self.base / 'cache')}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        setup_legacy(self.root)

    def test_cli_preflight_runs_with_current_interpreter_without_vault(self):
        env = {'ORBIT_STATE': str(self.base / 'unbound-state'), 'ORBIT_CONFIG': str(self.base / 'unbound.json'),
               'ORBIT_CACHE': str(self.base / 'unbound-cache')}
        for flag, expected in (('--help', 'setup'), ('--version', orbit.VERSION)):
            with self.subTest(flag=flag):
                result = subprocess.run([sys.executable, str(Path(orbit.__file__)), flag],
                                        cwd=self.base, env=env, capture_output=True,
                                        text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)
        self.assertFalse(Path(env['ORBIT_CONFIG']).exists())
        self.assertFalse(Path(env['ORBIT_CACHE']).exists())

    def test_identity_rules_journals_search_and_capture_survive(self):
        marker = (self.root / '.orbit/vault.json').read_bytes()
        rules = self.root / 'ORBIT.md'
        rules.write_text('# Custom rules\nKeep my content.\n')
        orbit.setup(str(self.root), 'Test')
        self.assertEqual((self.root / '.orbit/vault.json').read_bytes(), marker)
        self.assertEqual(rules.read_text(), '# Custom rules\nKeep my content.\n')
        receipt = orbit.apply(self.root, plan())
        journal = self.root / '.orbit/operations' / (receipt['operation'] + '.json')
        self.assertEqual(json.loads(journal.read_text())['status'], 'committed')
        self.assertEqual(orbit.search(self.root, 'staged deployment')['results'][0]['path'], 'Knowledge/Atlas.md')
        source = self.base / 'source.txt'
        source.write_text('A retained source')
        orbit.capture(self.root, str(source))
        self.assertTrue(list((self.root / '.orbit/integrations').glob('*.json')))
        self.assertEqual(knowledge.catalog(self.root)['total'], 1)

    def test_lock_and_pending_operation_block_writes(self):
        with orbit.lock(self.root):
            self.assertTrue((self.root / '.orbit/write.lock').is_file())
            with self.assertRaisesRegex(orbit.OrbitError, 'write lock'):
                orbit.apply(self.root, plan())
        operations = self.root / '.orbit/operations'
        operations.mkdir()
        (operations / 'pending.json').write_text(json.dumps({'status': 'prepared', 'id': 'pending'}))
        self.assertEqual(orbit.doctor(self.root)['pending_operations'], ['pending'])
        with self.assertRaisesRegex(orbit.OrbitError, 'pending operation'):
            orbit.apply(self.root, plan())

    def test_explicit_config_and_cache_paths(self):
        with patch.dict(os.environ, {'ORBIT_CONFIG': str(self.base / 'chosen.json')}):
            self.assertEqual(orbit.config_path(), self.base / 'chosen.json')
        os.environ['ORBIT_CACHE'] = str(self.base / 'new-cache')
        self.assertEqual(retrieval.cache_path(self.root).parent, self.base / 'new-cache')

    def test_hidden_state_cannot_be_read_as_notes(self):
        for directory in ('.orbit', '.private'):
            folder = self.root / directory
            folder.mkdir(exist_ok=True)
            (folder / 'private.md').write_text('private content')
            with self.assertRaises(orbit.OrbitError):
                orbit.read(self.root, directory + '/private.md')
