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
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--resources', required=True, type=Path)
    parser.add_argument('--output', default=ROOT / 'dist/swift-candidate', type=Path)
    parser.add_argument('--acceptance-root', type=Path, help='Isolate host verification from personal registries and folders')
    parser.add_argument('--candidate-version', default='0.7.0-dev', help='Installable candidate version; does not publish a package release')
    args = parser.parse_args()
    binary = args.binary.resolve()
    bundle = args.resources.resolve()
    if not binary.is_file() or not any(bundle.glob('**/contract.json')):
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
    setup_reference = plugin / 'references/setup.md'
    setup_text = setup_reference.read_text()
    start = setup_text.index('The plugin provides local MCP tools')
    end = setup_text.index('\n\n## Check the connection first', start)
    setup_text = setup_text[:start] + ('This native candidate provides MCP tools through bin/orbit-mcp and OrbitCore. '
                  'It does not require or bundle Python. The companion checkout retains Python only as the compatibility reference and shipping runtime pending native acceptance. '
                  'Configuration, cache and recovery state remain outside the installed plugin.') + setup_text[end:]
    setup_reference.write_text(setup_text)
    tools_reference = plugin / 'references/tools.md'
    tools_text = tools_reference.read_text().replace(
        'The optional `scripts/orbit.py` CLI remains available for engineering and recovery.',
        'The Python reference CLI remains in the companion source checkout for engineering and recovery; it is not bundled in this native candidate.')
    tools_reference.write_text(tools_text)
    native = plugin / 'bin'
    native.mkdir()
    shutil.copy2(binary, native / 'orbit-mcp')
    (native / 'orbit-mcp').chmod(0o755)
    shutil.copytree(bundle, native / bundle.name)
    version = args.candidate_version
    plugin_name = 'orbit-swift-acceptance' if args.acceptance_root else 'orbit'
    acceptance_env = {}
    if args.acceptance_root:
        acceptance = args.acceptance_root.resolve()
        acceptance.mkdir(parents=True, exist_ok=True)
        acceptance_env = {'ORBIT_CONFIG': str(acceptance / 'config.json'), 'ORBIT_CACHE': str(acceptance / 'cache'), 'ORBIT_STATE': str(acceptance / 'state')}
    for host, launch in [('.mcp.json', '${CLAUDE_PLUGIN_ROOT}/bin/orbit-mcp'), ('.codex.mcp.json', './bin/orbit-mcp')]:
        server = {'command': launch, 'args': []}
        if acceptance_env:
            server['args'] = ['--config', acceptance_env['ORBIT_CONFIG'], '--cache', acceptance_env['ORBIT_CACHE'], '--state', acceptance_env['ORBIT_STATE']]
        if host == '.codex.mcp.json':
            # Resolve the system launcher before cwd; resolve the native path inside cwd.
            server['command'] = '/usr/bin/env'
            server['args'] = ['./bin/orbit-mcp', *server['args']]
            server['cwd'] = '.'
        (plugin / host).write_text(json.dumps({'mcpServers': {plugin_name: server}}, indent=2) + '\n')
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    if args.acceptance_root:
        manifest['display_name'] = 'Orbit Swift acceptance'
        manifest['description'] = 'Disposable verification of the native Orbit runtime.'
    manifest.update(name=plugin_name, version=version, server={'type': 'binary', 'entry_point': 'bin/orbit-mcp',
                    'mcp_config': {'command': '${__dirname}/bin/orbit-mcp', 'args': []}},
                    compatibility={'platforms': ['darwin']})
    if acceptance_env:
        manifest['server']['mcp_config']['args'] = ['--config', acceptance_env['ORBIT_CONFIG'], '--cache', acceptance_env['ORBIT_CACHE'], '--state', acceptance_env['ORBIT_STATE']]
    (plugin / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for host in ('.codex-plugin', '.claude-plugin'):
        path = plugin / host / 'plugin.json'
        data = json.loads(path.read_text()); data['version'] = version; data['name'] = plugin_name
        if args.acceptance_root:
            data['description'] = 'Disposable verification of the native Orbit runtime.'
            if 'interface' in data:
                data['interface']['displayName'] = 'Orbit Swift acceptance'
        path.write_text(json.dumps(data, indent=2) + '\n')
    for host, source in [('.claude-plugin', {'name': 'orbit-swift-local', 'owner': {'name': 'Orbit'}, 'plugins': [{'name': 'orbit', 'source': './plugins/orbit'}]}),
                         ('.agents/plugins', {'name': 'orbit-swift-local', 'plugins': [{'name': 'orbit', 'source': {'source': 'local', 'path': './plugins/orbit'}, 'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'}, 'category': 'Productivity'}]})]:
        source['plugins'][0]['name'] = plugin_name
        path = out / 'marketplace' / host / 'marketplace.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(source, indent=2) + '\n')
    paths = sorted(p for p in plugin.rglob('*') if p.is_file())
    for filename in ('orbit-swift-plugin.zip', 'orbit-swift.mcpb'):
        with zipfile.ZipFile(out / filename, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in paths:
                archive.write(path, path.relative_to(plugin))
    receipt = {'status': 'candidate', 'package_version': version, 'plugin_name': plugin_name, 'mcp_server_name': plugin_name, 'acceptance_only': bool(acceptance_env),
               'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'runtime': 'native Swift', 'python_runtime_files': [],
               'desktop_host_acceptance': 'NOT VERIFIED',
               'files': {p.relative_to(plugin).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'marketplace': str(out / 'marketplace'), 'receipt': str(out / 'receipt.json')}))


if __name__ == '__main__':
    main()
