import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]

class PackageTest(unittest.TestCase):
    def test_skill_references_and_no_hooks(self):
        skills = list((ROOT / 'skills').glob('*/SKILL.md'))
        self.assertEqual(len(skills), 6)
        self.assertEqual([p.parent.name for p in skills if 'migrate' in p.parent.name], ['orbit-migrate'])
        for p in skills:
            text = p.read_text()
            self.assertTrue(text.startswith('---\nname:'))
            for relative in re.findall(r'\]\((\.\./[^)]+)\)', text):
                self.assertTrue((p.parent / relative).resolve().is_file(), (p, relative))
        for name in ('.claude-plugin', '.codex-plugin'):
            manifest = json.loads((ROOT / name / 'plugin.json').read_text())
            self.assertEqual(manifest['name'], 'orbit')
            self.assertNotIn('hooks', manifest)
            self.assertTrue((ROOT / manifest['mcpServers']).is_file())
            self.assertTrue((ROOT / manifest['skills']).is_dir())

    def test_distributable(self):
        run = subprocess.run([sys.executable, str(ROOT / 'scripts/package.py')], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        with zipfile.ZipFile(ROOT / 'dist/orbit-plugin.zip') as archive:
            names = archive.namelist()
            self.assertIn('.claude-plugin/plugin.json', names)
            self.assertIn('.codex-plugin/plugin.json', names)
            for required in ('bin/orbit-mcp', '.mcp.json', '.codex.mcp.json', 'manifest.json',
                             'references/schemas/Session.md', 'skills/orbit-format/SKILL.md',
                             'skills/orbit-migrate/SKILL.md', 'skills/orbit-migrate/references/format-1-to-2.md'):
                self.assertIn(required, names)
            self.assertTrue(any(name.startswith('bin/OrbitCore_OrbitCore.bundle/') and name.endswith('contract.json')
                                for name in names))
            self.assertFalse(any(name.endswith('.py') or name.startswith('scripts/') for name in names))
            self.assertTrue(stat.S_IMODE(archive.getinfo('bin/orbit-mcp').external_attr >> 16) & stat.S_IXUSR)
            manifest = json.loads(archive.read('manifest.json'))
            self.assertEqual(manifest['server']['type'], 'binary')
            self.assertEqual(manifest['server']['entry_point'], 'bin/orbit-mcp')
            self.assertNotIn('python', manifest.get('compatibility', {}).get('runtimes', {}))
            self.assertFalse(any('__pycache__' in n or 'write.lock' in n for n in names))
        with zipfile.ZipFile(ROOT / 'dist/orbit.mcpb') as archive:
            self.assertEqual(set(archive.namelist()), set(names))
        with zipfile.ZipFile(ROOT / 'dist/orbit-project.zip') as archive:
            source_names = archive.namelist()
            for required in ('orbit/Package.swift', 'orbit/Sources/OrbitCore/OrbitEngine.swift',
                             'orbit/scripts/orbit.py', 'orbit/scripts/mcp_server.py',
                             'orbit/tests/test_orbit.py', 'orbit/tests/OrbitCoreTests/ContractTests.swift',
                             'orbit/dist/marketplace/plugins/orbit/bin/orbit-mcp'):
                self.assertIn(required, source_names)
            self.assertFalse(any('/.build/' in name or '/__pycache__/' in name for name in source_names))
        receipt = json.loads((ROOT / 'dist/receipt.json').read_text())
        self.assertEqual(receipt['runtime'], 'native Swift')
        self.assertEqual(receipt['python_runtime_files'], [])
        self.assertEqual(receipt['desktop_host_acceptance'], 'NOT VERIFIED')
        for path in ('.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'):
            manifest = json.loads((ROOT / 'dist/marketplace' / path).read_text())
            self.assertEqual(manifest['plugins'][0]['name'], 'orbit')
            self.assertEqual(manifest['name'], 'orbit-local')

    def test_rebuild_removes_superseded_python_from_staged_plugin(self):
        stale = ROOT / 'dist/marketplace/plugins/orbit/scripts/stale-python.py'
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_text('raise RuntimeError("must not ship")\n')
        unrelated = ROOT / 'dist/marketplace/unrelated-test-config.json'
        unrelated.write_text('{"disposable_test_only": true}\n')
        self.addCleanup(unrelated.unlink, missing_ok=True)
        run = subprocess.run([sys.executable, str(ROOT / 'scripts/package.py')], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(stale.exists())
        self.assertFalse((stale.parent).exists())
        with zipfile.ZipFile(ROOT / 'dist/orbit-project.zip') as archive:
            self.assertFalse(any(name.endswith('/unrelated-test-config.json') for name in archive.namelist()))

if __name__ == '__main__': unittest.main()
