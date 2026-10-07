import json
from pathlib import Path
import re
import subprocess
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]

class PackageTest(unittest.TestCase):
    def test_skill_references_and_no_hooks(self):
        skills = list((ROOT / 'skills').glob('*/SKILL.md'))
        self.assertEqual(len(skills), 4)
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
            self.assertIn('scripts/orbit.py', names)
            for required in ('scripts/mcp_server.py', '.mcp.json', '.codex.mcp.json', 'manifest.json'):
                self.assertIn(required, names)
            self.assertFalse(any('__pycache__' in n or 'write.lock' in n for n in names))
        for path in ('.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'):
            manifest = json.loads((ROOT / 'dist/marketplace' / path).read_text())
            self.assertEqual(manifest['plugins'][0]['name'], 'orbit')

if __name__ == '__main__': unittest.main()
