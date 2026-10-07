#!/usr/bin/env python3
"""Build a portable plugin ZIP and local marketplaces, excluding runtime data."""
import json
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'dist'

def main():
    DEST.mkdir(exist_ok=True)
    market = DEST / 'marketplace'
    plugin = market / 'plugins/orbit'
    plugin.mkdir(parents=True, exist_ok=True)
    shipped = set()
    for name in ('skills', 'references', 'scripts', '.claude-plugin', '.codex-plugin'):
        shutil.copytree(ROOT / name, plugin / name, dirs_exist_ok=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'eval.py'))
        shipped.update(p.relative_to(ROOT) for p in (ROOT / name).rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.pyc' and p.name != 'eval.py')
    for name in ('README.md', 'LOCAL_TEST.md', 'HANDOFF.md', '.mcp.json', '.codex.mcp.json', 'manifest.json'):
        shutil.copy2(ROOT / name, plugin / name)
        shipped.add(Path(name))
    for stale in plugin.rglob('*'):
        if stale.is_file() and stale.relative_to(plugin) not in shipped:
            stale.unlink()
    for folder, data in [('.claude-plugin', {'name': 'orbit-local', 'owner': {'name': 'Orbit'}, 'plugins': [{'name': 'orbit', 'source': './plugins/orbit', 'description': 'Local knowledge for your agents'}]}),
                         ('.agents/plugins', {'name': 'orbit-local', 'plugins': [{'name': 'orbit', 'source': {'source': 'local', 'path': './plugins/orbit'}, 'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'}, 'category': 'Productivity'}]})]:
        p = market / folder / 'marketplace.json'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    with zipfile.ZipFile(DEST / 'orbit-plugin.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for relative in sorted(shipped):
            archive.write(plugin / relative, relative)
    with zipfile.ZipFile(DEST / 'orbit.mcpb', 'w', zipfile.ZIP_DEFLATED) as archive:
        for relative in sorted(shipped):
            archive.write(plugin / relative, relative)
    with zipfile.ZipFile(DEST / 'orbit-project.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        project = set(shipped)
        project.update(Path(name) for name in ('AGENTS.md', '.gitignore', 'scripts/eval.py', '.agents/plugins/marketplace.json'))
        project.update(p.relative_to(ROOT) for p in (ROOT / 'tests').rglob('*') if p.is_file() and p.suffix in ('.py', '.json'))
        for relative in sorted(project):
            archive.write(ROOT / relative, Path('orbit') / relative)
        for relative in sorted(shipped):
            archive.write(plugin / relative, Path('orbit/dist/marketplace/plugins/orbit') / relative)
        for relative in ('.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'):
            archive.write(market / relative, Path('orbit/dist/marketplace') / relative)
        archive.write(DEST / 'orbit-plugin.zip', 'orbit/dist/orbit-plugin.zip')
    print(json.dumps({'project_zip': str(DEST / 'orbit-project.zip'), 'plugin_zip': str(DEST / 'orbit-plugin.zip'), 'desktop_extension': str(DEST / 'orbit.mcpb'), 'marketplace': str(market)}, indent=2))

if __name__ == '__main__': main()
