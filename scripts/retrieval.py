"""Rebuildable local passage search; authoritative notes remain in the vault."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat

SCHEMA = 3
BUDGET = 12000


def cache_path(root):
    import orbit
    identity = json.loads(orbit.safe(root, orbit.internal(root) + '/vault.json').read_text())['id']
    key = hashlib.sha256((str(root.resolve()) + '\0' + identity).encode()).hexdigest()
    directory = Path(os.environ.get('ORBIT_CACHE') or os.environ.get('SECOND_BRAIN_CACHE') or str(orbit.config_path().parent / 'cache')).expanduser()
    if directory.resolve().is_relative_to(root.resolve()):
        raise OSError('Search cache must be outside the vault')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / (key + '.sqlite3')
    if path.is_symlink():
        raise OSError('Search cache must not be a symlink')
    return path


def inventory(root):
    import orbit
    for base, dirs, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        prefix = base_path.relative_to(root).as_posix()
        if prefix != '.':
            orbit.safe(root, prefix)
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and not (base_path / d).is_symlink())
        for name in sorted(files):
            relative = name if prefix == '.' else prefix + '/' + name
            if not name.lower().endswith('.md') or relative.startswith('Sources/assets/'):
                continue
            info = (base_path / name).lstat()
            if not stat.S_ISREG(info.st_mode):
                continue
            yield relative, json.dumps([info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns])


def passages(text):
    lines = text.splitlines()
    start = 0
    if lines and lines[0].lstrip('\ufeff') == '---':
        start = next((i + 1 for i in range(1, len(lines)) if lines[i] == '---'), 0)
    heading = []
    fence = None
    begin = start
    size = 0
    for i in range(start, len(lines)):
        line = lines[i]
        marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        title = re.match(r'^(#{1,6})\s+(.+)', line) if fence is None else None
        if title:
            if i > begin and any(lines[begin:i]):
                yield begin + 1, i, ' / '.join(heading), '\n'.join(lines[begin:i])
            depth = len(title[1])
            heading = heading[:depth - 1] + [title[2]]
            begin, size = i, 0
        if marker:
            if fence is None:
                fence = marker[1]
            elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                fence = None
        size += len(line) + 1
        if fence is None and not line.strip() and size >= 1800:
            yield begin + 1, i + 1, ' / '.join(heading), '\n'.join(lines[begin:i + 1])
            begin, size = i + 1, 0
    if begin < len(lines) and any(lines[begin:]):
        yield begin + 1, len(lines), ' / '.join(heading), '\n'.join(lines[begin:])


def connect(path):
    db = sqlite3.connect(path, timeout=3)
    db.row_factory = sqlite3.Row
    os.chmod(path, 0o600)
    return db


def initialize(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS notes(path TEXT PRIMARY KEY, signature TEXT, sha256 TEXT,
            identity TEXT, title TEXT, aliases TEXT, project TEXT, status TEXT);
        CREATE TABLE IF NOT EXISTS passages(id INTEGER PRIMARY KEY, path TEXT, start INTEGER,
            end INTEGER, section TEXT, body TEXT);
        CREATE INDEX IF NOT EXISTS passage_path ON passages(path);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(title, aliases, section, body, tokenize='porter unicode61');
    ''')
    db.execute(f'PRAGMA user_version={SCHEMA}')


def refresh(root, rebuild=False):
    import orbit
    path = cache_path(root)
    try:
        db = connect(path)
        version = db.execute('PRAGMA user_version').fetchone()[0]
        if version not in (0, SCHEMA):
            rebuild = True
    except sqlite3.DatabaseError as error:
        if 'db' in locals():
            db.close()
        code = getattr(error, 'sqlite_errorcode', 0) & 0xff
        if code not in (sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB):
            raise
        path.unlink(missing_ok=True)
        db = connect(path)
    try:
        if rebuild:
            db.executescript('DROP TABLE IF EXISTS search; DROP TABLE IF EXISTS passages; DROP TABLE IF EXISTS notes;')
        initialize(db)
        current = dict(inventory(root))
        stored = {row['path']: row['signature'] for row in db.execute('SELECT path,signature FROM notes')}
        changed = [p for p in current if current[p] != stored.get(p)]
        removed = set(stored) - set(current)
        with db:
            for relative in [*changed, *removed]:
                db.execute('DELETE FROM search WHERE rowid IN (SELECT id FROM passages WHERE path=?)', (relative,))
                db.execute('DELETE FROM passages WHERE path=?', (relative,))
                db.execute('DELETE FROM notes WHERE path=?', (relative,))
            for relative in changed:
                raw = orbit.safe(root, relative).read_bytes()
                text = raw.decode('utf-8-sig')
                meta = orbit.metadata(text)
                match = re.search(r'^#\s+(.+)$', text, re.M)
                title = str(meta.get('title') or (match[1] if match else Path(relative).stem))
                aliases = orbit.strings(meta.get('aliases'))
                db.execute('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?)', (relative, current[relative], orbit.digest(raw),
                    str(meta.get('id', '')), title, json.dumps(aliases), str(meta.get('project', '')), str(meta.get('status', 'current'))))
                for start, end, section, body in passages(text):
                    rowid = db.execute('INSERT INTO passages(path,start,end,section,body) VALUES(?,?,?,?,?)',
                        (relative, start, end, section, body)).lastrowid
                    db.execute('INSERT INTO search(rowid,title,aliases,section,body) VALUES(?,?,?,?,?)', (rowid,title,' '.join(aliases),section,body))
        return {'mode': 'sqlite-fts5-passages', 'cache': str(path), 'notes': len(current),
            'passages': db.execute('SELECT count(*) FROM passages').fetchone()[0],
            'inventoried': len(current), 'reparsed': len(changed), 'deleted': len(removed)}
    finally:
        db.close()


def search(root, query, limit=8, scope=None):
    import orbit
    terms = list(dict.fromkeys(orbit.tokens(query)))
    freshness = refresh(root)
    if not terms:
        return {'mode': 'sqlite-fts5-passages', 'total': 0, 'results': [], 'freshness': freshness,
            'coverage': {'state': 'complete', 'semantic': False, 'truncated': False}}
    match = ' OR '.join('"' + word.replace('"', '""') + '"' for word in terms)
    def order(row):
        names = [row['title'], *json.loads(row['aliases'])]
        exact = query.casefold().strip() in [name.casefold() for name in names]
        return (not exact, row['rank'], row['path'])
    bounded_limit = max(1, min(limit, 100))
    for attempt in range(2):
        db = connect(Path(freshness['cache']))
        try:
            db.execute('BEGIN')
            sql = '''SELECT n.*,p.start,p.end,p.section,p.id AS passage_id,bm25(search,5,4,2,1) AS rank
                FROM search JOIN passages p ON p.id=search.rowid JOIN notes n ON n.path=p.path
                WHERE search MATCH ?'''
            params = [match]
            if scope:
                sql += " AND (n.project=? OR n.path=? OR substr(n.path,1,?)=?)"
                prefix = scope.rstrip('/') + '/'
                params.extend([scope, scope, len(prefix), prefix])
            best = set()
            selected = []
            for row in db.execute(sql + ' ORDER BY rank,n.path,p.start', params):
                if row['path'] in best:
                    continue
                best.add(row['path'])
                selected.append(dict(row))
                selected.sort(key=order)
                if len(selected) > bounded_limit:
                    selected.pop()
            overview = {}
            for selected_row in selected:
                selected_row['body'] = db.execute('SELECT body FROM passages WHERE id=?', (selected_row['passage_id'],)).fetchone()['body']
                opening = db.execute('SELECT * FROM passages WHERE path=? ORDER BY start LIMIT 1', (selected_row['path'],)).fetchone()
                if opening:
                    overview[opening['path']] = opening
        finally:
            db.close()
        stale = any(orbit.digest(orbit.safe(root, row['path']).read_bytes()) != row['sha256'] for row in selected)
        if not stale:
            break
        if attempt:
            raise OSError('Retrieved evidence changed repeatedly; retry against current files')
        freshness = refresh(root, rebuild=True)
    result = {'mode': 'sqlite-fts5-passages', 'total': len(best), 'results': [], 'freshness': freshness,
        'coverage': {'state': 'complete', 'semantic': False, 'truncated': False},
        'hint': 'Read evidence and adjacent qualifications before answering. Lexical retrieval has no semantic matching.'}
    for row in selected:
        excerpts = {row['start']: row}
        if row['path'] in overview:
            opening = overview[row['path']]
            excerpts[opening['start']] = opening
        candidate = {'path': row['path'], 'title': row['title'], 'id': row['identity'] or None,
            'project': row['project'] or None, 'status': row['status'], 'sha256': row['sha256'],
            'score': -row['rank'], 'matched': [t for t in terms if t in set(orbit.tokens(row['body'] + ' ' + row['title'] + ' ' + ' '.join(json.loads(row['aliases']))))],
            'start': min(excerpts), 'end': max(p['end'] for p in excerpts.values()),
            'section': row['section'], 'snippets': []}
        result['results'].append(candidate)
        if len(json.dumps(result, ensure_ascii=False, indent=2)) > BUDGET:
            result['results'].pop()
            result['coverage']['truncated'] = True
            break
        exhausted = False
        for excerpt in sorted(excerpts.values(), key=lambda p: p['start']):
            for offset, line in enumerate(excerpt['body'].splitlines()):
                snippet = {'line': excerpt['start'] + offset, 'text': line}
                candidate['snippets'].append(snippet)
                if len(json.dumps(result, ensure_ascii=False, indent=2)) > BUDGET:
                    candidate['snippets'].pop()
                    result['coverage']['truncated'] = True
                    exhausted = True
                    break
            if exhausted:
                break
        if exhausted:
            break
    return result
