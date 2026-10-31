#!/usr/bin/env python3
"""Stage an independently named native acceptance candidate from a built runtime.

The normal release builder is package.py and consumes committed bin/ artifacts.
This helper can isolate native host verification from personal registrations. It
never establishes desktop-host acceptance or publishes a release.
"""
import argparse
import hashlib
import json
from pathlib import Path

import package as packaging

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--resources', required=True, type=Path)
    parser.add_argument('--output', default=ROOT / 'dist/swift-candidate', type=Path)
    parser.add_argument('--acceptance-root', type=Path, help='Isolate host verification from personal registries and folders')
    parser.add_argument('--candidate-version', default=json.loads((ROOT / 'manifest.json').read_text())['version'], help='Installable candidate version; defaults to the source manifest version')
    args = parser.parse_args()
    binary = args.binary.resolve()
    bundle = args.resources.resolve()
    try:
        packaging.validate_runtime(binary, bundle)
    except ValueError as error:
        parser.error(str(error))
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    plugin = out / 'marketplace/plugins/orbit'
    packaging.stage_plugin(plugin, binary, bundle)
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
    packaging.validate_native_manifests(plugin)
    packaging.write_marketplace(out / 'marketplace', name='orbit-swift-local', plugin_name=plugin_name)
    paths = sorted(p for p in plugin.rglob('*') if p.is_file())
    for filename in ('orbit-swift-plugin.zip', 'orbit-swift.mcpb'):
        packaging.archive_plugin(plugin, out / filename)
    receipt = {'status': 'candidate', 'package_version': version, 'plugin_name': plugin_name, 'mcp_server_name': plugin_name, 'acceptance_only': bool(acceptance_env),
               'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'runtime': 'native Swift', 'python_runtime_files': [],
               'desktop_host_acceptance': 'NOT VERIFIED',
               'files': {p.relative_to(plugin).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'marketplace': str(out / 'marketplace'), 'receipt': str(out / 'receipt.json')}))


if __name__ == '__main__':
    main()
