"""Immutable accepted snapshots and conservative local Markdown checkout.

The folder transports evidence, not locks. Reconciliation never invents ancestry.
Callers retain responsibility for note/schema and integration-domain validation.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import uuid

import orbit

_PROTOCOL = 1
_MAX_BYTES = 64 * 1024 * 1024
_locks = {}
_locks_guard = threading.Lock()


def _hash(value):
    return hashlib.sha256(_encode(value)).hexdigest()


def _encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def _identity(root):
    try:
        value = json.loads(orbit.safe(root, '.orbit/vault.json').read_bytes())['id']
        uuid.UUID(value)
        return value
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise orbit.OrbitError('Replication requires a valid Orbit identity') from exc


def enabled(root):
    try:
        return json.loads(orbit.safe(root, '.orbit/vault.json').read_bytes()).get('data_format') == 3
    except (OSError, ValueError):
        return False


def _state(root):
    base = Path(os.environ.get('ORBIT_STATE', str(Path.home() / '.local/state/orbit'))).expanduser().resolve()
    root = Path(root).resolve()
    if base.is_relative_to(root):
        raise orbit.OrbitError('ORBIT_STATE must be outside the synced Orbit folder')
    return base / _hash([str(root), _identity(root)])


@contextmanager
def local_lock(root):
    """Serialize local threads/processes; nesting in one thread is safe."""
    directory = _state(root)
    key = str(directory)
    with _locks_guard:
        entry = _locks.setdefault(key, (threading.RLock(), threading.local()))
    mutex, local = entry
    with mutex:
        if getattr(local, 'depth', 0):
            local.depth += 1
            try:
                yield
            finally:
                local.depth -= 1
            return
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / 'write.lock').open('a+b') as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            local.depth = 1
            try:
                yield
            finally:
                local.depth = 0
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def _path(root, value):
    if not isinstance(value, str):
        raise orbit.OrbitError('Snapshot path must be a string')
    path = orbit.safe(root, value)
    parts = Path(value).parts
    integration = len(parts) == 3 and parts[:2] == ('.orbit', 'integrations') and re.fullmatch(r'[a-f0-9]{64}\.json', parts[2])
    if not integration and (any(p.startswith('.') for p in parts) or path.suffix.lower() != '.md' or parts[:2] == ('Sources', 'assets')):
        raise orbit.OrbitError('Snapshot must target Markdown or an integration record')
    if path.relative_to(root).as_posix() != value:
        raise orbit.OrbitError('Snapshot path must be canonical')
    return path


def _entity(path, text):
    if path.startswith('.orbit/integrations/'):
        return 'integration:' + Path(path).stem
    meta = orbit.metadata(text) if text is not None else {}
    note_id = meta.get('id')
    return 'note:' + note_id if isinstance(note_id, str) and note_id else 'path:' + path


def _text(root, path):
    p = _path(root, path)
    try:
        return p.read_bytes().decode('utf-8') if p.exists() else None
    except (OSError, UnicodeError) as exc:
        raise orbit.OrbitError('Cannot read snapshot target ' + path) from exc


def _uuid(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError):
        raise orbit.OrbitError('request_id must be a canonical UUID string')
    return value


def _publish(root, directory, name, record):
    path = orbit.safe(root, '.orbit/' + directory + '/' + name + '.json')
    raw = _encode(record)
    if len(raw) > _MAX_BYTES:
        raise orbit.OrbitError('Snapshot exceeds 64 MiB limit')
    if path.exists():
        if path.read_bytes() != raw:
            raise orbit.OrbitError('Immutable snapshot identity collision: ' + name)
        return
    orbit.atomic(path, raw)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _assets(versions):
    found = set()
    for version in versions:
        content = version['content'] or ''
        for match in re.finditer(r'Sources/assets/([a-f0-9]{64})(\.[a-zA-Z0-9]{1,10})(?![a-zA-Z0-9])', content):
            found.add(('Sources/assets/' + match[1] + match[2], match[1]))
    return [{'path': p, 'sha256': h} for p, h in sorted(found)]


def _envelope(root, operation_id, writes, versions, request_digest, *, genesis=False):
    payload = {'protocol': _PROTOCOL, 'vault_id': _identity(root), 'id': operation_id,
               'request_digest': request_digest, 'genesis': genesis, 'writes': writes,
               'versions': versions, 'assets': _assets(versions)}
    return dict(payload, sha256=_hash(payload))


def _validate(root, record, filename):
    if not isinstance(record, dict):
        raise orbit.OrbitError('Snapshot must be an object')
    payload = {k: v for k, v in record.items() if k != 'sha256'}
    if record.get('sha256') != _hash(payload):
        raise orbit.OrbitError('Snapshot integrity mismatch')
    if record.get('protocol') != _PROTOCOL or record.get('vault_id') != _identity(root):
        raise orbit.OrbitError('Unsupported snapshot protocol or different Orbit identity')
    if _uuid(record.get('id')) + '.json' != filename:
        raise orbit.OrbitError('Snapshot filename does not match identity')
    if not isinstance(record.get('request_digest'), str) or type(record.get('genesis')) is not bool:
        raise orbit.OrbitError('Invalid snapshot request metadata')
    versions, writes = record.get('versions'), record.get('writes')
    if not isinstance(versions, list) or not versions or not isinstance(writes, list) or not writes:
        raise orbit.OrbitError('Snapshot requires versions and writes')
    entities, destinations, write_paths = set(), set(), set()
    for write in writes:
        if not isinstance(write, dict):
            raise orbit.OrbitError('Invalid snapshot write')
        _path(root, write.get('path'))
        if write['path'] in write_paths:
            raise orbit.OrbitError('Duplicate snapshot write path')
        write_paths.add(write['path'])
        if not all(write.get(key) is None or isinstance(write.get(key), str) for key in ('before', 'after')):
            raise orbit.OrbitError('Snapshot text must be UTF-8 text or null')
    for version in versions:
        if not isinstance(version, dict):
            raise orbit.OrbitError('Invalid entity version')
        entity, path, content = version.get('entity'), version.get('path'), version.get('content')
        _path(root, path)
        if not isinstance(entity, str) or not entity or entity in entities:
            raise orbit.OrbitError('Invalid or duplicate entity')
        entities.add(entity)
        if content is not None and not isinstance(content, str):
            raise orbit.OrbitError('Invalid entity content')
        if content is not None and _entity(path, content) != entity and not entity.startswith('path:'):
            raise orbit.OrbitError('Entity identity differs from content')
        if content is not None and path in destinations:
            raise orbit.OrbitError('Duplicate snapshot destination')
        if content is not None:
            destinations.add(path)
        for key in ('parents', 'observations', 'paths'):
            values = version.get(key)
            if not isinstance(values, list) or any(not isinstance(v, str) for v in values) or values != sorted(set(values)):
                raise orbit.OrbitError('Invalid ' + key + ' set')
        if not version['paths'] or path not in version['paths']:
            raise orbit.OrbitError('Missing version path')
        for p in version['paths']:
            _path(root, p)
        matching = [w for w in writes if w['path'] in version['paths']]
        retired = version.get('retired', False)
        if retired and (retired is not True or content is not None or not version['parents']
                        or not any(v['entity'] != entity and v['path'] == path and v['content'] is not None for v in versions)):
            raise orbit.OrbitError('Invalid collision retirement')
        if not matching or (not retired and not any(w['path'] == path and w.get('after') == content for w in matching)):
            raise orbit.OrbitError('Version does not match its write evidence')
        if set(version['paths']) != {w['path'] for w in matching}:
            raise orbit.OrbitError('Missing write evidence')
    if write_paths != {p for v in versions for p in v['paths']}:
        raise orbit.OrbitError('Unassigned write evidence')
    assets = record.get('assets')
    if assets != _assets(versions):
        raise orbit.OrbitError('Asset dependencies differ from content')
    return record


def _load(root):
    records, invalid = {}, []
    folder = orbit.safe(root, '.orbit/commits')
    for path in sorted(folder.glob('*.json')):
        try:
            orbit.safe(root, path.relative_to(root).as_posix())
            if path.stat().st_size > _MAX_BYTES:
                raise orbit.OrbitError('Snapshot exceeds size limit')
            record = _validate(root, json.loads(path.read_bytes()), path.name)
            records[record['id']] = record
        except (OSError, ValueError, TypeError, KeyError, orbit.OrbitError) as exc:
            invalid.append({'path': path.relative_to(root).as_posix(), 'error': str(exc)})
    if not records and enabled(root):
        invalid.append({'path': '.orbit/commits', 'error': 'Format 3 history is missing'})
    return records, invalid


def _observations(root):
    observations, invalid = {}, []
    for path in sorted(orbit.safe(root, '.orbit/observations').glob('*.json')):
        try:
            orbit.safe(root, path.relative_to(root).as_posix())
            if path.stat().st_size > _MAX_BYTES:
                raise orbit.OrbitError('Observation exceeds size limit')
            record = json.loads(path.read_bytes())
            if not isinstance(record, dict) or record.get('vault_id') != _identity(root) or record.get('protocol') != _PROTOCOL:
                raise orbit.OrbitError('Invalid observation identity/protocol')
            _path(root, record.get('path'))
            if not isinstance(record.get('content'), str) or not isinstance(record.get('entity'), str) or (_entity(record['path'], record['content']) != record['entity'] and not record['entity'].startswith('path:')):
                raise orbit.OrbitError('Invalid observation content/identity')
            observation_id = _hash(record)
            if path.name != observation_id + '.json':
                raise orbit.OrbitError('Observation integrity mismatch')
            observations[observation_id] = record
        except (OSError, ValueError, TypeError, KeyError, orbit.OrbitError) as exc:
            invalid.append({'path': path.relative_to(root).as_posix(), 'error': str(exc)})
    return observations, invalid


def _fold(root):
    records, invalid = _load(root)
    observations, bad_observations = _observations(root)
    invalid += bad_observations
    versions, owners = {}, {}
    for oid, record in records.items():
        for index, version in enumerate(record['versions']):
            token = record['sha256'] + ':' + str(index)
            versions[token], owners[token] = version, oid
    eligible, pending = set(), {}
    remaining = set(records)
    while remaining:
        progressed = False
        for oid in sorted(remaining):
            record = records[oid]
            reasons = []
            for version in record['versions']:
                for parent in version['parents']:
                    if parent not in versions:
                        reasons.append('missing parent ' + parent)
                    elif versions[parent]['entity'] != version['entity']:
                        reasons.append('parent belongs to another entity ' + parent)
                    elif version['content'] is not None and versions[parent]['content'] is not None and not version['entity'].startswith('integration:') and orbit.metadata(versions[parent]['content']).get('id') and orbit.metadata(versions[parent]['content']).get('id') != orbit.metadata(version['content']).get('id'):
                        reasons.append('parent stable identity changed ' + parent)
                    elif owners[parent] not in eligible:
                        reasons.append('pending parent ' + parent)
                for observation in version['observations']:
                    if observation not in observations:
                        reasons.append('missing observation ' + observation)
                    elif observations[observation]['entity'] != version['entity']:
                        reasons.append('observation belongs to another entity ' + observation)
            for asset in record['assets']:
                path = orbit.safe(root, asset['path'])
                if not path.is_file():
                    reasons.append('missing asset ' + asset['path'])
                elif orbit.digest(path.read_bytes()) != asset['sha256']:
                    reasons.append('asset hash mismatch ' + asset['path'])
            if reasons:
                pending[oid] = sorted(set(reasons))
            else:
                eligible.add(oid)
                remaining.remove(oid)
                pending.pop(oid, None)
                progressed = True
        if not progressed:
            break
    active = {t: v for t, v in versions.items() if owners[t] in eligible}
    parents = {p for v in active.values() for p in v['parents']}
    heads = {}
    for token, version in active.items():
        if token not in parents:
            heads.setdefault(version['entity'], []).append(token)
    heads = {e: sorted(h) for e, h in heads.items()}
    known_bytes = {(v['path'], v['content']) for v in versions.values() if v['content'] is not None}
    consumed = {o for v in active.values() for o in v['observations']}
    unresolved = {oid: o for oid, o in observations.items() if oid not in consumed and (o['path'], o['content']) not in known_bytes}
    state_for_observation = {'versions': versions, 'observations': observations}
    for observation_id, observation in _unfamiliar(root, state_for_observation).items():
        if observation_id not in consumed:
            unresolved[observation_id] = observation
    return {'records': records, 'versions': versions, 'owners': owners, 'eligible': eligible,
            'heads': heads, 'observations': observations, 'unresolved': unresolved,
            'pending': pending, 'invalid': invalid, 'local_paths': sorted(_local_paths(root))}


def _report(state):
    versions = state['versions']
    conflicts, blocked, by_path = [], set(), {}
    entities = set(state['heads']) | {o['entity'] for o in state['unresolved'].values()}
    claims = {}
    for entity in sorted(entities):
        heads = state['heads'].get(entity, [])
        obs = sorted(i for i, o in state['unresolved'].items() if o['entity'] == entity)
        paths = {p for t in heads for p in versions[t]['paths']}
        paths.update(state['unresolved'][i]['path'] for i in obs)
        for p in paths:
            by_path.setdefault(p, []).extend(heads)
        for t in heads:
            if versions[t]['content'] is not None:
                claims.setdefault(versions[t]['path'], set()).add(entity)
        if len(heads) > 1 or obs:
            conflicts.append({'entity': entity, 'paths': sorted(paths), 'heads': heads, 'observations': obs})
            blocked.update(paths)
    for path, entities_at_path in sorted(claims.items()):
        if len(entities_at_path) > 1:
            blocked.add(path)
            for entity in sorted(entities_at_path):
                if not any(c['entity'] == entity for c in conflicts):
                    heads = state['heads'][entity]
                    paths = sorted({p for t in heads for p in versions[t]['paths']})
                    conflicts.append({'entity': entity, 'paths': paths, 'heads': heads, 'observations': [], 'reason': 'path collision'})
                    blocked.update(paths)
    identities = {}
    for entity, tokens in state['heads'].items():
        for token in tokens:
            version = versions[token]
            if version['content'] is not None and not entity.startswith('integration:'):
                note_id = orbit.metadata(version['content']).get('id')
                if isinstance(note_id, str) and note_id:
                    identities.setdefault(note_id, {}).setdefault(entity, set()).update(version['paths'])
    for identity, owners in identities.items():
        if len(owners) > 1:
            for entity, paths in sorted(owners.items()):
                blocked.update(paths)
                if not any(c['entity'] == entity for c in conflicts):
                    conflicts.append({'entity': entity, 'paths': sorted(paths), 'heads': state['heads'][entity],
                                      'observations': [], 'reason': 'duplicate stable identity ' + identity})
    for oid in state['pending']:
        blocked.update(p for v in state['records'][oid]['versions'] for p in v['paths'])
    changed = True
    while changed:
        changed = False
        for oid in state['eligible']:
            record = state['records'][oid]
            if record['genesis']:
                continue
            active_tokens = {t for ts in state['heads'].values() for t in ts}
            paths = {p for t, v in versions.items() if state['owners'][t] == oid and t in active_tokens for p in v['paths']}
            if paths & blocked and not paths <= blocked:
                blocked.update(paths)
                changed = True
    for path, claimed_entities in claims.items():
        if len(claimed_entities) == 1 and path not in blocked:
            owner = next(iter(claimed_entities))
            by_path[path] = state['heads'][owner]
    if state['invalid']:
        blocked.update(state['local_paths'])
        blocked.update(p for v in versions.values() for p in v['paths'])
    return {'status': 'invalid' if state['invalid'] else 'conflicted' if conflicts else 'pending' if state['pending'] else 'ready',
            'conflicts': sorted(conflicts, key=lambda c: c['entity']),
            'pending': [{'operation': k, 'reasons': v} for k, v in sorted(state['pending'].items())],
            'invalid': state['invalid'], 'blocked_paths': sorted(blocked),
            'heads': {p: sorted(set(h)) for p, h in sorted(by_path.items())}}


def inspect(root):
    return _report(_fold(Path(root)))


def history(root, path):
    root = Path(root)
    _path(root, path)
    state = _fold(root)
    entities = {v['entity'] for v in state['versions'].values() if path in v['paths']}
    entities.update(o['entity'] for o in state['observations'].values() if o['path'] == path)
    revisions = []
    for token, version in sorted(state['versions'].items()):
        if version['entity'] in entities:
            revisions.append(dict(version, revision=token, operation=state['owners'][token],
                                  eligible=state['owners'][token] in state['eligible']))
    current = _text(root, path)
    return {'path': path, 'current': {'path': path, 'content': current,
                                    'sha256': orbit.digest(current.encode('utf-8')) if current is not None else None},
            'revisions': revisions,
            'observations': [dict(o, id=i) for i, o in sorted(state['observations'].items()) if o['entity'] in entities],
            'sync': _report(state)}


def _local_paths(root):
    paths = set()
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if not d.startswith('.') and not (Path(base) / d).is_symlink()]
        for name in files:
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            if path.suffix.lower() == '.md' and not path.is_symlink() and not rel.startswith('Sources/assets/'):
                paths.add(rel)
    for path in orbit.safe(root, '.orbit/integrations').glob('*.json'):
        paths.add(path.relative_to(root).as_posix())
    return paths


def _resolved_entity(state, path, text):
    entity = _entity(path, text)
    legacy = {v['entity'] for v in state['versions'].values()
              if v['entity'].startswith('path:') and path in v['paths']}
    legacy.update(o['entity'] for o in (state.get('observations', {}) | state.get('unresolved', {})).values()
                  if o['entity'].startswith('path:') and o['path'] == path)
    return next(iter(legacy)) if len(legacy) == 1 else entity


def _unfamiliar(root, state):
    paths = _local_paths(root) | {p for v in state['versions'].values() for p in v['paths']}
    known = {(v['path'], v['content']) for v in state['versions'].values()}
    observations = {}
    for path in sorted(paths):
        text = _text(root, path)
        if text is None or (path, text) in known:
            continue
        observation = {'protocol': _PROTOCOL, 'vault_id': _identity(root),
                       'entity': _resolved_entity(state, path, text), 'path': path, 'content': text}
        observations[_hash(observation)] = observation
    return observations


def _capture(root, state):
    for observation_id, observation in _unfamiliar(root, state).items():
        _publish(root, 'observations', observation_id, observation)


def reconcile(root):
    root = Path(root)
    with local_lock(root):
        state = _fold(root)
        _capture(root, state)
        state = _fold(root)
        report = _report(state)
        materialized = []
        if report['invalid']:
            return dict(report, materialized=materialized)
        blocked = set(report['blocked_paths'])
        intent_path = _state(root) / 'checkout.json'
        live_claims = {state['versions'][t]['path'] for tokens in state['heads'].values()
                       for t in tokens if state['versions'][t]['content'] is not None}
        for entity, tokens in sorted(state['heads'].items()):
            if len(tokens) != 1:
                continue
            version = state['versions'][tokens[0]]
            if set(version['paths']) & blocked:
                continue
            desired = {p: None for p in version['paths']}
            desired[version['path']] = version['content']
            for path, after in sorted(desired.items()):
                if after is None and path in live_claims:
                    continue
                before = _text(root, path)
                if before == after:
                    continue
                # Only an observed historical value can be replaced. An editor racing
                # this check remains outside filesystem compare-and-swap guarantees.
                known = {v['content'] for v in state['versions'].values() if v['path'] == path}
                known.update(o['content'] for o in state['observations'].values() if o['path'] == path)
                if before is not None and before not in known:
                    _capture(root, state)
                    return dict(_report(_fold(root)), materialized=materialized)
                orbit.atomic(intent_path, _encode({'path': path, 'before': before, 'after': after, 'head': tokens[0]}))
                if _text(root, path) != before:
                    _capture(root, state)
                    return dict(_report(_fold(root)), materialized=materialized)
                target = _path(root, path)
                if after is None:
                    target.unlink(missing_ok=True)
                else:
                    orbit.atomic(target, after.encode('utf-8'))
                materialized.append(path)
                intent_path.unlink(missing_ok=True)
        return dict(_report(_fold(root)), materialized=materialized)


def _genesis(root, files):
    if not isinstance(files, dict) or any(not isinstance(v, str) for v in files.values()):
        raise orbit.OrbitError('Genesis requires a mapping of paths to text')
    operation_id = str(uuid.uuid5(uuid.UUID(_identity(root)), 'orbit-format-3-genesis'))
    versions, writes, entities = [], [], set()
    for path, text in sorted(files.items()):
        _path(root, path)
        entity = _entity(path, text)
        if entity in entities:
            raise orbit.OrbitError('Genesis contains duplicate stable identities')
        entities.add(entity)
        versions.append({'entity': entity, 'path': path, 'content': text, 'parents': [], 'observations': [], 'paths': [path]})
        writes.append({'path': path, 'before': text, 'after': text, 'reason': 'Format 3 genesis'})
    if not writes:
        raise orbit.OrbitError('Genesis requires at least one file, such as ORBIT.md')
    return _envelope(root, operation_id, writes, versions, _hash(files), genesis=True)


def seed_preview(root, files):
    record = _genesis(Path(root), files)
    return {'operation': record['id'], 'path': '.orbit/commits/' + record['id'] + '.json',
            'sha256': orbit.digest(_encode(record))}


def seed(root, files):
    root = Path(root)
    with local_lock(root):
        record = _genesis(root, files)
        _publish(root, 'commits', record['id'], record)
        return {'status': 'committed', 'operation': record['id'], 'durability': 'local', 'verified': True}


def _receipt(root, record):
    try:
        sync = reconcile(root)
        verified = all(_text(root, w['path']) == w['after'] for w in record['writes'])
        return {'status': 'committed', 'operation': record['id'], 'durability': 'local', 'verified': verified, 'sync': sync}
    except (OSError, orbit.OrbitError) as exc:
        return {'status': 'committed', 'operation': record['id'], 'durability': 'local', 'verified': False,
                'sync': {'status': 'interrupted', 'error': str(exc), 'materialized': []}}


def _previous(root, request_id, request_digest):
    path = orbit.safe(root, '.orbit/commits/' + request_id + '.json')
    if not path.exists():
        return None
    try:
        record = _validate(root, json.loads(path.read_bytes()), path.name)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        raise orbit.OrbitError('Cannot read previous request') from exc
    if record['request_digest'] != request_digest:
        raise orbit.OrbitError('request_id was already used for different content')
    return record


def retry(root, request_id, request_digest):
    root = Path(root)
    _uuid(request_id)
    with local_lock(root):
        record = _previous(root, request_id, request_digest)
        return _receipt(root, record) if record is not None else None


def commit(root, writes, request_id=None, request_digest=None, dry_run=False):
    root = Path(root)
    operation_id = _uuid(request_id) if request_id is not None else str(uuid.uuid4())
    if not isinstance(writes, list) or not writes or len(writes) > 50:
        raise orbit.OrbitError('Commit requires 1 to 50 writes')
    request_digest = request_digest if request_digest is not None else _hash(writes)
    with local_lock(root):
        previous = _previous(root, operation_id, request_digest)
        if previous is not None:
            if dry_run:
                return {'status': 'preview', 'operation': operation_id, 'already_committed': True, 'sync': inspect(root)}
            return _receipt(root, previous)
        state = _fold(root)
        if not dry_run:
            _capture(root, state)
            state = _fold(root)
        report = _report(state)
        if report['invalid'] or report['pending']:
            raise orbit.OrbitError('Resolve invalid or incomplete sync evidence before saving')
        groups, clean, seen, retirements = {}, [], set(), []
        for write in writes:
            if not isinstance(write, dict):
                raise orbit.OrbitError('Invalid write')
            path = write.get('path')
            _path(root, path)
            if path in seen:
                raise orbit.OrbitError('Duplicate target in commit')
            seen.add(path)
            for key in ('expected_heads', 'observations'):
                if key in write and (not isinstance(write[key], list) or any(not isinstance(v, str) for v in write[key]) or len(set(write[key])) != len(write[key])):
                    raise orbit.OrbitError('Expected heads and observations must be unique string lists')
            before, after = write.get('before'), write.get('after')
            if any(v is not None and not isinstance(v, str) for v in (before, after)):
                raise orbit.OrbitError('Write content must be text or null')
            if _text(root, path) != before:
                raise orbit.OrbitError('Write conflict: ' + path + ' changed before commit')
            entity = _resolved_entity(state, path, after if after is not None else before)
            competing = {e: hs for e, hs in state['heads'].items()
                         if any(state['versions'][h]['path'] == path and state['versions'][h]['content'] is not None for h in hs)}
            resolving_collision = len(competing) > 1
            if resolving_collision:
                all_heads = sorted(h for hs in competing.values() for h in hs)
                all_observations = sorted(i for i, o in state['unresolved'].items() if o['entity'] in competing)
                if entity not in competing or after is None:
                    raise orbit.OrbitError('Choose the content of one existing identity to resolve the path collision')
                if sorted(write.get('expected_heads', [])) != all_heads:
                    raise orbit.OrbitError('Path collision: supply the exact union of expected_heads for every competing identity')
                if sorted(write.get('observations', [])) != all_observations:
                    raise orbit.OrbitError('Path collision: supply all observations for competing identities')
                for losing, losing_heads in competing.items():
                    if losing == entity:
                        continue
                    losing_paths = sorted({p for h in losing_heads for p in state['versions'][h]['paths']})
                    retirements.append({'entity': losing, 'path': path, 'content': None, 'parents': losing_heads,
                                        'observations': sorted(i for i in all_observations if state['unresolved'][i]['entity'] == losing),
                                        'paths': losing_paths, 'retired': True})
                write = dict(write, expected_heads=competing[entity],
                             observations=sorted(i for i in all_observations if state['unresolved'][i]['entity'] == entity))
            if not resolving_collision and before is not None and after is not None and orbit.metadata(before).get('id') and orbit.metadata(before).get('id') != orbit.metadata(after).get('id'):
                raise orbit.OrbitError('Preserve stable identity')
            groups.setdefault(entity, []).append(write)
            clean.append({'path': path, 'before': before, 'after': after, 'reason': str(write.get('reason', ''))})
        versions = []
        for entity, members in sorted(groups.items()):
            heads = state['heads'].get(entity, [])
            obs = sorted(i for i, o in state['unresolved'].items() if o['entity'] == entity)
            supplied_heads = [m['expected_heads'] for m in members if 'expected_heads' in m]
            supplied_obs = [m['observations'] for m in members if 'observations' in m]
            for supplied in supplied_heads + supplied_obs:
                if not isinstance(supplied, list) or any(not isinstance(s, str) for s in supplied) or len(set(supplied)) != len(supplied):
                    raise orbit.OrbitError('Expected heads and observations must be unique string lists')
            if any(sorted(s) != heads for s in supplied_heads) or ((len(heads) > 1 or (obs and heads)) and not supplied_heads):
                raise orbit.OrbitError('Conflict: supply exact expected_heads to resolve all branches')
            if any(sorted(s) != obs for s in supplied_obs) or (obs and not supplied_obs):
                raise orbit.OrbitError('External edit: supply exact observations to adopt or resolve')
            if len(heads) == 1 and not supplied_heads and not obs:
                head = state['versions'][heads[0]]
                matching = [m for m in members if m['path'] == head['path']]
                if not matching or matching[0].get('before') != head['content']:
                    raise orbit.OrbitError('Write conflict: current bytes do not match the accepted head; reconcile and read again')
            live = [m for m in members if m.get('after') is not None]
            if len(live) > 1 or not live and len(members) > 1:
                raise orbit.OrbitError('One entity requires one destination or one tombstone')
            selected = live[0] if live else members[0]
            paths = sorted({m['path'] for m in members} | {p for h in heads for p in state['versions'][h]['paths']})
            for old_path in sorted(set(paths) - {m['path'] for m in members}):
                if old_path in seen:
                    raise orbit.OrbitError('Another entity targets a retained historical path')
                old_content = _text(root, old_path)
                if old_content is not None and _resolved_entity(state, old_path, old_content) != entity:
                    raise orbit.OrbitError('Historical path is occupied by another entity')
                clean.append({'path': old_path, 'before': old_content, 'after': None, 'reason': 'Retain prior-location tombstone'})
                seen.add(old_path)
            versions.append({'entity': entity, 'path': selected['path'], 'content': selected.get('after'),
                             'parents': heads, 'observations': obs, 'paths': paths})
        for retired in retirements:
            if retired['entity'] in groups:
                raise orbit.OrbitError('A retired collision identity cannot also be updated in this operation')
            for old_path in retired['paths']:
                if old_path in seen:
                    continue
                old_content = _text(root, old_path)
                if old_content is not None and _resolved_entity(state, old_path, old_content) != retired['entity']:
                    raise orbit.OrbitError('Retired historical path is occupied by another identity')
                clean.append({'path': old_path, 'before': old_content, 'after': None, 'reason': 'Retire collision identity'})
                seen.add(old_path)
            versions.append(retired)
        record = _envelope(root, operation_id, clean, versions, request_digest)
        _validate(root, record, operation_id + '.json')
        for write in clean:
            if _text(root, write['path']) != write['before']:
                raise orbit.OrbitError('Write conflict before durable acceptance: ' + write['path'])
        if dry_run:
            return {'status': 'preview', 'sync': report}
        _publish(root, 'commits', operation_id, record)
        return _receipt(root, record)


def operation(root, operation_id):
    root = Path(root)
    _uuid(operation_id)
    state = _fold(root)
    if operation_id not in state['eligible']:
        raise orbit.OrbitError('Operation is unavailable, incomplete or invalid')
    record = state['records'][operation_id]
    return {'id': operation_id, 'status': 'committed', 'writes': record['writes'], 'durability': 'local'}
