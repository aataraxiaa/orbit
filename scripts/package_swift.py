#!/usr/bin/env python3
"""Stage a native candidate without changing the shipping Python manifests.

Supply an already built binary and its SwiftPM resource bundle. This is an
acceptance candidate, never evidence of desktop-host installation or release.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--resources', required=True, type=Path)
    parser.add_argument('--output', default=ROOT / 'dist/swift-candidate', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    bundle = args.resources.resolve()
    if not binary.is_file() or not (bundle / 'Resources/contract.json').is_file():
        parser.error('Supply the native executable and matching OrbitCore resource bundle')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    plugin = out / 'marketplace/plugins/orbit'
    # Refuse reuse to avoid mixing stale runtime files into the native artifact.
    if plugin.exists():
        shutil.rmtree(plugin)
    plugin.mkdir(parents=True)
    for name in ('skills', 'references', '.claude-plugin', '.codex-plugin', 'assets'):
        shutil.copytree(ROOT / name, plugin / name)
    for name in ('README.md', 'LOCAL_TEST.md', 'HANDOFF.md'):
        shutil.copy2(ROOT / name, plugin / name)
    native = plugin / 'bin'
    native.mkdir()
    shutil.copy2(binary, native / 'orbit-mcp')
    (native / 'orbit-mcp').chmod(0o755)
    shutil.copytree(bundle, native / bundle.name)
    version = '0.7.0-dev'
    for host, launch in [('.mcp.json', '${CLAUDE_PLUGIN_ROOT}/bin/orbit-mcp'), ('.codex.mcp.json', './bin/orbit-mcp')]:
        server = {'command': launch, 'args': []}
        if host == '.codex.mcp.json':
            server['cwd'] = '.'
        (plugin / host).write_text(json.dumps({'mcpServers': {'orbit': server}}, indent=2) + '\n')
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    manifest.update(version=version, server={'type': 'binary', 'entry_point': 'bin/orbit-mcp',
                    'mcp_config': {'command': '${__dirname}/bin/orbit-mcp', 'args': []}},
                    compatibility={'platforms': ['darwin']})
    (plugin / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for host in ('.codex-plugin', '.claude-plugin'):
        path = plugin / host / 'plugin.json'
        data = json.loads(path.read_text()); data['version'] = version
        path.write_text(json.dumps(data, indent=2) + '\n')
    for host, source in [('.claude-plugin', {'name': 'orbit-swift-local', 'owner': {'name': 'Orbit'}, 'plugins': [{'name': 'orbit', 'source': './plugins/orbit'}]}),
                         ('.agents/plugins', {'name': 'orbit-swift-local', 'plugins': [{'name': 'orbit', 'source': {'source': 'local', 'path': './plugins/orbit'}, 'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'}, 'category': 'Productivity'}]})]:
        path = out / 'marketplace' / host / 'marketplace.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(source, indent=2) + '\n')
    paths = sorted(p for p in plugin.rglob('*') if p.is_file())
    for filename in ('orbit-swift-plugin.zip', 'orbit-swift.mcpb'):
        with zipfile.ZipFile(out / filename, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in paths:
                archive.write(path, path.relative_to(plugin))
    receipt = {'status': 'candidate', 'package_version': version,
               'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'runtime': 'native Swift', 'python_runtime_files': [],
               'desktop_host_acceptance': 'NOT VERIFIED',
               'files': {p.relative_to(plugin).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'marketplace': str(out / 'marketplace'), 'receipt': str(out / 'receipt.json')}))


if __name__ == '__main__':
    main()
