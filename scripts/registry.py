"""Named Orbit configuration and immutable operation targets."""
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import uuid

import orbit


@dataclass(frozen=True)
class Target:
    name: str
    root: Path
    vault_id: str
    source: str

    def receipt(self):
        return {'name': self.name, 'path': str(self.root), 'vault_id': self.vault_id,
                'selection_source': self.source}


def name_key(name):
    if not isinstance(name, str) or not name.strip() or name != name.strip() or len(name) > 80 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
        raise orbit.OrbitError('Orbit name must contain 1 to 80 characters without surrounding whitespace or control characters')
    return name.casefold()


def identity(root):
    marker = orbit.safe(root, orbit.INTERNAL + '/vault.json')
    try:
        value = json.loads(marker.read_bytes())['id']
        if not isinstance(value, str):
            raise ValueError('Expected a UUID string')
        uuid.UUID(value)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise orbit.OrbitError('Orbit folder is unavailable or has an invalid identity: ' + str(root)) from exc
    return value


def read_config():
    cfg = orbit.config_path()
    raw = cfg.read_bytes() if cfg.exists() else b''
    try:
        data = json.loads(raw) if raw else {'schema': 2, 'orbits': {}}
    except ValueError as exc:
        raise orbit.OrbitError('Invalid Orbit config JSON') from exc
    validate(data)
    return data


def validate(data):
    if not isinstance(data, dict) or type(data.get('schema')) is not int or data.get('schema') != 2:
        raise orbit.OrbitError('Unsupported Orbit config schema')
    entries = data.get('orbits')
    if not isinstance(entries, dict) or 'vault' in data:
        raise orbit.OrbitError('Malformed named Orbit registry')
    keys, roots, ids = set(), [], set()
    for name, entry in entries.items():
        key = name_key(name)
        if not isinstance(entry, dict) or not isinstance(entry.get('path'), str) or not isinstance(entry.get('vault_id'), str):
            raise orbit.OrbitError('Malformed Orbit registry entry')
        root = Path(entry['path'])
        try:
            uuid.UUID(entry['vault_id'])
        except ValueError as exc:
            raise orbit.OrbitError('Malformed registered Orbit identity') from exc
        if not root.is_absolute() or os.path.normpath(entry['path']) != entry['path']:
            raise orbit.OrbitError('Registered paths must be absolute and canonical')
        if key in keys or entry['vault_id'] in ids or any(root.is_relative_to(p) or p.is_relative_to(root) for p in roots):
            raise orbit.OrbitError('Duplicate name, identity, or overlapping Orbit roots')
        keys.add(key)
        ids.add(entry['vault_id'])
        roots.append(root)


def checked(name, entry, source):
    root = Path(entry['path'])
    if root.resolve() != root:
        raise orbit.OrbitError('Registered Orbit path now resolves elsewhere: ' + name)
    observed = identity(root)
    if observed != entry['vault_id']:
        raise orbit.OrbitError('Registered Orbit identity changed; refusing operation: ' + name)
    return Target(name, root, observed, source)


def resolve(name=None, path=None):
    if name is not None and path is not None:
        raise orbit.OrbitError('Choose an Orbit name or folder path, not both')
    data = read_config()
    entries = data['orbits']
    if name is not None:
        key = name_key(name)
        for display, entry in entries.items():
            if name_key(display) == key:
                return checked(display, entry, 'orbit')
        raise orbit.OrbitError('Unknown Orbit name: ' + name)
    if path is None and len(entries) != 1:
        raise orbit.OrbitError('Select an explicit Orbit name; the registry has zero or multiple entries')
    if path:
        root = Path(path).expanduser().resolve()
        for display, entry in entries.items():
            if root == Path(entry['path']):
                return checked(display, entry, 'vault')
        raise orbit.OrbitError('Selected path is not a registered Orbit')
    display, entry = next(iter(entries.items()))
    return checked(display, entry, 'only-orbit')


def list_orbits():
    data = read_config()
    results = []
    for name, entry in data.get('orbits', {}).items():
        item = {'name': name, 'path': entry['path'], 'vault_id': entry['vault_id']}
        try:
            checked(name, entry, 'list')
            item['status'] = 'available'
        except (orbit.OrbitError, OSError, RuntimeError) as exc:
            item.update(status='unavailable', error=str(exc))
        results.append(item)
    return {'schema': 2, 'orbits': results}


@contextmanager
def config_lock():
    cfg = orbit.config_path()
    cfg.parent.mkdir(parents=True, exist_ok=True)
    # flock releases on process death; the stable sibling inode is never removed.
    with (cfg.parent / (cfg.name + '.lock')).open('a+b') as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        yield


def sync_parent(path):
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def registration(data, root, name, vault_id):
    key = name_key(name)
    entries = dict(data.get('orbits', {}))
    for display, entry in entries.items():
        if name_key(display) == key:
            if display != name or entry['path'] != str(root) or entry['vault_id'] != vault_id:
                raise orbit.OrbitError('Orbit name already exists; rebinding or case collisions are not allowed')
            return data
        other = Path(entry['path'])
        if root.is_relative_to(other) or other.is_relative_to(root) or (vault_id and entry['vault_id'] == vault_id):
            raise orbit.OrbitError('Duplicate identity or overlapping Orbit roots')
    entries[name] = {'path': str(root), 'vault_id': vault_id}
    return dict(data, orbits=entries)


def setup(path, name, create=False):
    name_key(name)
    if not Path(path).expanduser().is_absolute():
        raise orbit.OrbitError('Registration requires an absolute path')
    root = Path(path).expanduser().resolve()
    if root in (Path('/'), Path.home(), Path(__file__).resolve().parents[1]):
        raise orbit.OrbitError('Choose a dedicated Orbit directory')
    if root.exists() and not root.is_dir():
        raise orbit.OrbitError('Orbit folder must be a directory')
    if not root.exists() and not create:
        raise orbit.OrbitError('Directory does not exist; use create=true to create it')
    with config_lock():
        current = read_config()
        marker = orbit.safe(root, '.orbit/vault.json')
        vault_id = identity(root) if marker.exists() else None
        registration(current, root, name, vault_id)
        if vault_id is None or json.loads(marker.read_text()).get('initializing'):
            orbit.initialize(str(root), create=create)
            vault_id = identity(root)
        updated = registration(current, root, name, vault_id)
        validate(updated)
        changed = updated != current
        if changed:
            orbit.atomic(orbit.config_path(), orbit.encode(updated))
            sync_parent(orbit.config_path())
    return {'status': 'registered' if changed else 'unchanged', 'vault': str(root), 'vault_id': vault_id,
            'config': str(orbit.config_path()),
            'target': Target(name, root, vault_id, 'setup').receipt()}


def rename(orbit_name, name):
    key = name_key(orbit_name)
    new_key = name_key(name)
    with config_lock():
        current = read_config()
        entries = current['orbits']
        display = next((n for n in entries if name_key(n) == key), None)
        if display is None:
            raise orbit.OrbitError('Unknown Orbit name: ' + orbit_name)
        if any(name_key(n) == new_key and n != display for n in entries):
            raise orbit.OrbitError('Orbit name already exists: ' + name)
        target = checked(display, entries[display], 'rename')
        changed = display != name
        if changed:
            updated = dict(current, orbits={name if n == display else n: entry for n, entry in entries.items()})
            validate(updated)
            orbit.atomic(orbit.config_path(), orbit.encode(updated))
            sync_parent(orbit.config_path())
    return {'status': 'renamed' if changed else 'unchanged', 'previous_name': display,
            'target': Target(name, target.root, target.vault_id, 'rename').receipt()}
