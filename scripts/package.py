#!/usr/bin/env python3
"""Package the committed native desktop runtime and a separate source archive.

This script never builds Swift or establishes desktop-host acceptance. Build and
verify bin/orbit-mcp and its matching resources through MobileBuildMCP first.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'dist'
BUNDLE_NAME = 'OrbitCore_OrbitCore.bundle'
MACHO_MAGICS = {bytes.fromhex(value) for value in ('cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
                                                'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe')}
EXCLUDED = {'__pycache__', '.DS_Store', '.git', '.build', '.swiftpm'}
RUNTIME_DIRECTORIES = ('skills', 'references', '.claude-plugin', '.codex-plugin', 'assets', 'docs')
RUNTIME_FILES = ('README.md', 'LOCAL_TEST.md', 'HANDOFF.md', '.mcp.json', '.codex.mcp.json', 'manifest.json')


def usable(path):
    return not any(part in EXCLUDED for part in path.parts) and path.suffix != '.pyc'


def validate_runtime(binary, resources):
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError('Missing executable native runtime: build bin/orbit-mcp through MobileBuildMCP first')
    with binary.open('rb') as stream:
        if stream.read(4) not in MACHO_MAGICS:
            raise ValueError('bin/orbit-mcp must be a built Mach-O executable, not a script or runtime launcher')
    if not resources.is_dir() or not any(resources.glob('**/contract.json')):
        raise ValueError('Missing matching OrbitCore resource bundle with contract.json')


def stage_plugin(plugin, binary, resources):
    validate_runtime(binary, resources)
    if plugin.exists():
        shutil.rmtree(plugin)
    plugin.mkdir(parents=True)
    for name in RUNTIME_DIRECTORIES:
        shutil.copytree(ROOT / name, plugin / name,
                        ignore=shutil.ignore_patterns(*EXCLUDED, '*.pyc'))
    for name in RUNTIME_FILES:
        shutil.copy2(ROOT / name, plugin / name)
    native = plugin / 'bin'
    native.mkdir()
    shutil.copy2(binary, native / 'orbit-mcp')
    (native / 'orbit-mcp').chmod(0o755)
    shutil.copytree(resources, native / BUNDLE_NAME,
                    ignore=shutil.ignore_patterns(*EXCLUDED, '*.pyc'))
    return sorted(path for path in plugin.rglob('*') if path.is_file())


def validate_native_manifests(plugin):
    for filename in ('.mcp.json', '.codex.mcp.json'):
        servers = json.loads((plugin / filename).read_text(encoding='utf-8'))['mcpServers']
        if not servers:
            raise ValueError('Native package has no MCP server configuration')
        for server in servers.values():
            command, arguments = server['command'], server.get('args', [])
            executable = arguments[0] if command == '/usr/bin/env' and arguments else command
            if not executable.endswith('/bin/orbit-mcp'):
                raise ValueError('Desktop manifests must launch bin/orbit-mcp without Python')
    manifest = json.loads((plugin / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['server']['type'] != 'binary' or manifest['server']['entry_point'] != 'bin/orbit-mcp':
        raise ValueError('MCPB must declare the native binary entry point')
    if 'python' in manifest.get('compatibility', {}).get('runtimes', {}):
        raise ValueError('Native MCPB must not require a Python runtime')
    if any(path.suffix == '.py' for path in plugin.rglob('*') if path.is_file()):
        raise ValueError('Python reference files must stay outside the production plugin')
    return manifest


def write_marketplace(market, name='orbit-local', plugin_name='orbit'):
    manifests = [('.claude-plugin', {'name': name, 'owner': {'name': 'Orbit'}, 'plugins': [
        {'name': plugin_name, 'source': './plugins/orbit', 'description': 'Local knowledge for your agents'}]}),
        ('.agents/plugins', {'name': name, 'plugins': [
            {'name': plugin_name, 'source': {'source': 'local', 'path': './plugins/orbit'},
             'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'}, 'category': 'Productivity'}]})]
    for folder, data in manifests:
        path = market / folder / 'marketplace.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def archive_plugin(plugin, destination):
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(path for path in plugin.rglob('*') if path.is_file()):
            archive.write(path, path.relative_to(plugin))


def source_files():
    files = {Path(name) for name in (*RUNTIME_FILES, 'AGENTS.md', '.gitignore', 'Package.swift')}
    for optional in ('Package.resolved', 'LICENSE', 'LICENSE.md'):
        if (ROOT / optional).is_file():
            files.add(Path(optional))
    for name in (*RUNTIME_DIRECTORIES, 'Sources', 'scripts', 'tests', 'docs', '.agents', 'bin'):
        files.update(path.relative_to(ROOT) for path in (ROOT / name).rglob('*')
                     if path.is_file() and usable(path.relative_to(ROOT)))
    return sorted(files)


def main():
    binary, resources = ROOT / 'bin/orbit-mcp', ROOT / 'bin' / BUNDLE_NAME
    # Validate before replacing a previous staged package.
    validate_runtime(binary, resources)
    DEST.mkdir(exist_ok=True)
    market = DEST / 'marketplace'
    plugin = market / 'plugins/orbit'
    stage_plugin(plugin, binary, resources)
    manifest = validate_native_manifests(plugin)
    write_marketplace(market)
    for name in ('orbit-plugin.zip', 'orbit.mcpb'):
        archive_plugin(plugin, DEST / name)
    with zipfile.ZipFile(DEST / 'orbit-project.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for relative in source_files():
            archive.write(ROOT / relative, Path('orbit') / relative)
        for path in sorted(path for path in plugin.rglob('*') if path.is_file()):
            archive.write(path, Path('orbit/dist/marketplace/plugins/orbit') / path.relative_to(plugin))
        for relative in ('.claude-plugin/marketplace.json', '.agents/plugins/marketplace.json'):
            archive.write(market / relative, Path('orbit/dist/marketplace') / relative)
        for name in ('orbit-plugin.zip', 'orbit.mcpb'):
            archive.write(DEST / name, Path('orbit/dist') / name)
    paths = sorted(path for path in plugin.rglob('*') if path.is_file())
    receipt = {'status': 'packaged', 'package_version': manifest['version'], 'runtime': 'native Swift',
               'python_runtime_files': [], 'desktop_host_acceptance': 'NOT VERIFIED',
               'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'files': {path.relative_to(plugin).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in paths}}
    (DEST / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'project_zip': str(DEST / 'orbit-project.zip'),
                      'plugin_zip': str(DEST / 'orbit-plugin.zip'),
                      'desktop_extension': str(DEST / 'orbit.mcpb'),
                      'marketplace': str(market), 'receipt': str(DEST / 'receipt.json')}, indent=2))


if __name__ == '__main__':
    main()
