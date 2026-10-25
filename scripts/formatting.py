"""Add absent Orbit metadata without rewriting existing Markdown bytes."""
from __future__ import annotations

import json
from pathlib import Path
import re
import uuid

import orbit

REQUIRED = ('id', 'title', 'type', 'summary')
LINE_BREAKS = '\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029'


def required_scalar(value):
    value = value.strip()
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except ValueError:
            raise orbit.OrbitError('Required metadata must use a supported single-line string')
    elif value.startswith("'"):
        if len(value) < 2 or not value.endswith("'") or "'" in value[1:-1]:
            raise orbit.OrbitError('Required metadata must use a supported single-line string')
        parsed = value[1:-1]
    else:
        if (not value or value[0] in '[]{}&*!|>@`%#?:,-' or ' #' in value or ': ' in value
                or value.lower() in ('null', '~', 'true', 'false', 'yes', 'no', 'on', 'off')
                or re.fullmatch(r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?', value)):
            raise orbit.OrbitError('Required metadata must use a supported nonempty string')
        parsed = value
    if not isinstance(parsed, str) or not parsed.strip() or any(c in parsed for c in LINE_BREAKS + '\x00'):
        raise orbit.OrbitError('Required metadata must use a supported nonempty single-line string')
    return parsed


def header(raw):
    """Locate an exact header; leave unknown metadata blocks opaque."""
    text = raw.decode('utf-8')
    bom = '\ufeff' if text.startswith('\ufeff') else ''
    text = text[len(bom):]
    lines = text.splitlines(keepends=True)
    newline = next((m.group() for m in re.finditer(r'\r\n|\n|\r', text)), '\n')
    if not lines or lines[0].rstrip('\r\n') != '---':
        if lines and lines[0].strip() == '---':
            raise orbit.OrbitError('Ambiguous frontmatter delimiter')
        return bom, '', text, {}, newline
    if lines[0] == '---':
        raise orbit.OrbitError('Unclosed frontmatter')
    fields, seen, current = {}, set(), None
    for index, line in enumerate(lines[1:], 1):
        content = line.rstrip('\r\n')
        if content == '---':
            return bom, ''.join(lines[:index + 1]), ''.join(lines[index + 1:]), fields, newline
        if not content.strip() or content.lstrip().startswith('#'):
            continue
        if content[0].isspace():
            if current is None or current in REQUIRED:
                raise orbit.OrbitError('Unsupported continuation in required metadata')
            continue
        match = re.fullmatch(r'([A-Za-z_][\w-]*):(?:[ \t]+(.*)|[ \t]*)', content)
        if not match:
            raise orbit.OrbitError('Unsupported or malformed top-level frontmatter')
        current, value = match.groups()
        if current in seen:
            raise orbit.OrbitError(f'Duplicate frontmatter key: {current}')
        seen.add(current)
        if current in REQUIRED:
            fields[current] = required_scalar(value or '')
    raise orbit.OrbitError('Unclosed frontmatter')


def prepare(root, plan):
    if not isinstance(plan, dict) or set(plan) - {'changes', 'request_id'} or 'changes' not in plan or not isinstance(plan['changes'], list) or not 1 <= len(plan['changes']) <= 50:
        raise orbit.OrbitError('Format plan requires 1 to 50 changes')
    namespace = uuid.UUID(json.loads(orbit.safe(root, orbit.INTERNAL + '/vault.json').read_text())['id'])
    changes, receipts, seen = [], [], set()
    for change in plan['changes']:
        if not isinstance(change, dict) or set(change) - {'path', 'expected_sha256', 'metadata', 'expected_heads', 'observations'} or not {'path', 'expected_sha256', 'metadata'} <= set(change):
            raise orbit.OrbitError('Each format change requires only path, expected_sha256 and metadata')
        path = change['path']
        if not isinstance(path, str):
            raise orbit.OrbitError('Format path must be a string')
        target = orbit.safe(root, path)
        if (Path(path).as_posix() != path or any(p.startswith('.') for p in Path(path).parts)
                or target.suffix != '.md' or path == 'ORBIT.md' or Path(path).parts[:2] == ('Sources', 'assets')):
            raise orbit.OrbitError('Format requires public .md note paths, not configuration or assets')
        if path in seen:
            raise orbit.OrbitError('Duplicate target in format plan')
        seen.add(path)
        if not target.is_file():
            raise orbit.OrbitError(f'{path}: formatting requires an existing note')
        raw = target.read_bytes()
        if change['expected_sha256'] != orbit.digest(raw):
            raise orbit.OrbitError(f'{path}: conflict; read the latest note and supply its SHA-256')
        supplied = change['metadata']
        if not isinstance(supplied, dict) or set(supplied) - {'title', 'type', 'summary'}:
            raise orbit.OrbitError('Format metadata accepts only title, type and summary')
        for value in supplied.values():
            if not isinstance(value, str) or not value.strip() or any(c in value for c in LINE_BREAKS + '\x00'):
                raise orbit.OrbitError('Format metadata values must be nonempty single-line strings')
        bom, frontmatter, body, existing, newline = header(raw)
        additions = {}
        for key in REQUIRED:
            if key in existing:
                if key in supplied and supplied[key] != existing[key]:
                    raise orbit.OrbitError(f'{path}: preserve existing {key}')
            elif key == 'id':
                additions[key] = str(uuid.uuid5(namespace, path))
            elif key in supplied:
                additions[key] = supplied[key]
            else:
                raise orbit.OrbitError(f'{path}: supply missing {key} based on the note')
        inserted = ''.join(f'{key}: {json.dumps(value, ensure_ascii=False)}{newline}' for key, value in additions.items())
        if not additions:
            after = raw.decode('utf-8')
        elif frontmatter:
            first = frontmatter.splitlines(keepends=True)[0]
            after = bom + first + inserted + frontmatter[len(first):] + body
        else:
            after = bom + '---' + newline + inserted + '---' + newline + body
        receipts.append({'path': path, 'added': additions, 'before_sha256': orbit.digest(raw),
                         'after_sha256': orbit.digest(after.encode()), 'body_sha256': orbit.digest(body.encode())})
        changes.append({'path': path, 'expected_sha256': change['expected_sha256'], 'content': after,
                        'reason': 'Add absent Orbit metadata; preserve existing bytes',
                        **{key: change[key] for key in ('expected_heads', 'observations') if key in change}})
    return {'summary': 'Format existing notes in place', 'changes': changes}, receipts


def format_notes(root, plan, dry_run=True):
    return orbit._apply(root, plan, dry_run, format_metadata=True)
