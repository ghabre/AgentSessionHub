"""Local, read-only native session adapters and durable incremental handoff planning.

A receipt means the CLI recorded the handoff prompt, not proof the model read it.
"""
import collections
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import tempfile
import time
import uuid

TOOLS = ('codex', 'claude', 'claude-work', 'opencode')
MARKER = re.compile(r'hub-transfer-([0-9a-f]{32})\.md')
LEGACY = re.compile(r'recent-(codex|claude|opencode)-handoff/((?:ses_[A-Za-z0-9]+|[0-9a-f-]{36}))-\d{8}-\d{6}\.md')


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def native_path(value):
    if sys.platform == 'win32' and re.match(r'^/[a-zA-Z]/', value):
        return value[1] + ':' + value[2:]
    return value


def text_blocks(content):
    if isinstance(content, str):
        return content
    return '\n\n'.join((b.get('text') or '') for b in (content or [])
                       if isinstance(b, dict) and b.get('type') in ('text', 'input_text', 'output_text'))


def clean(text):
    text = re.sub(r'(?s)<system-reminder>.*?</system-reminder>', '', text)
    text = re.sub(r'(?s)<local-command-(stdout|stderr)>.*?</local-command-\1>', '', text)
    return text.strip()


def injected(text):
    return bool(re.match(r'^\s*(?:<(?:environment_context|user_instructions|skills_instructions|instructions)\b|#\s+\S+\.md instructions\b)', text))


class Session:
    def __init__(self, tool, sid, cwd='', title=''):
        self.key = tool + ':' + sid
        self.tool, self.id, self.cwd, self.title = tool, sid, cwd, title
        self.events, self.markers, self.legacy, self.timeline = [], [], [], []
        self.legacy_context = []
        self.combined_sources = []
        self.continued = None
        self.history_base = False
        self.active = True
        self.updated = 0
        self._counts = collections.Counter()

    def add(self, role, text, native_id=None):
        text = clean(text)
        if not text or (role == 'user' and injected(text)):
            return
        if role == 'user':
            inherited = re.search(r'inherited title: ([^\]]+)', text)
            if inherited and not self.title:
                self.title = inherited.group(1)
            markers = MARKER.findall(text)
            self.markers.extend(markers)
            self.timeline.extend({'transfer': marker} for marker in markers)
            legacy_text = text.replace('\\', '/')
            legacy = LEGACY.findall(legacy_text)
            combined = re.search(r'recent-(codex|claude|opencode)-handoff/combined-\d{8}-\d{6}\.md', legacy_text)
            self.legacy.extend((tool + ':' + sid) for tool, sid in legacy)
            if legacy or combined:
                match = re.search(r'Read (.+?recent-(?:codex|claude|opencode)-handoff/[^\r\n]*?\.md)', legacy_text)
                if match:
                    filename = match.group(1)
                    origin = legacy[0][0] + ':' + legacy[0][1] if legacy else 'legacy-combined:' + digest(filename)
                    context = (origin, filename)
                    if combined and Path(native_path(filename)).is_file():
                        snapshot = Path(native_path(filename)).read_text(encoding='utf-8-sig')
                        self.combined_sources = sorted(combined.group(1) + ':' + sid for sid in
                                                       re.findall(r'^- Session id: `([^`]+)`', snapshot, re.M))
                        self.legacy.extend(self.combined_sources)
                    self.legacy_context.append(context)
                    self.timeline.append({'legacy': context})
            if markers or legacy or combined:
                return
        if role == 'user' and not self.title:
            self.title = text.splitlines()[0][:80]
        fingerprint = digest(role + '\n' + text)
        self._counts[fingerprint] += 1
        # Occurrence distinguishes repeated identical turns. Content addresses survive
        # JSON reformatting and transcript relocation without relying on wall clocks.
        event_id = (f'{self.tool}:{native_id}:{fingerprint}' if native_id
                    else f'{self.key}:{fingerprint}:{self._counts[fingerprint]}')
        self.events.append({'id': event_id, 'origin': self.key, 'role': role, 'text': text})
        self.timeline.append({'event': event_id})

    def follow(self, base):
        """Append this paginated Codex segment to the earlier segments of the same thread."""
        for name in ('events', 'markers', 'legacy', 'legacy_context', 'timeline'):
            setattr(self, name, getattr(base, name) + getattr(self, name))
        self.title = base.title or self.title
        self.combined_sources = base.combined_sources or self.combined_sources

    def failure(self, text):
        if re.search(r'(?i)\b(error|failed|exception|traceback|denied|not found|cannot|unable|exit code [1-9])\b', text):
            self.add('tool failure', text[:700])

    def note(self, name, arguments):
        if not isinstance(arguments, dict):
            return
        fields = {k: arguments[k] for k in ('file_path', 'path', 'notebook_path', 'url', 'pattern', 'glob', 'command', 'cmd', 'workdir', 'query', 'code')
                  if arguments.get(k)}
        if fields:
            self.add('tool note', name + ': ' + json.dumps(fields, ensure_ascii=False))


def read_jsonl(path, tool):
    sid = path.stem
    if tool == 'codex':
        match = re.search(r'[0-9a-f-]{36}$', sid)
        if not match:
            return None
        sid = match.group()
    session = Session(tool, sid)
    with path.open(encoding='utf-8-sig', errors='replace') as stream:
        for line in stream:
            try:
                row = json.loads(line)
            except ValueError:
                continue  # An agent may still be writing the final JSONL record.
            kind = row.get('type')
            if tool == 'codex':
                payload = row.get('payload') or {}
                if kind == 'session_meta':
                    if payload.get('parent_thread_id') or (isinstance(payload.get('source'), dict) and 'subagent' in payload['source']):
                        session.active = False
                    session.id = payload.get('id') or sid
                    session.key = tool + ':' + session.id
                    session.cwd = payload.get('cwd') or session.cwd
                    session.history_base = bool(payload.get('history_base'))
                if kind == 'response_item':
                    if payload.get('type') == 'message' and payload.get('role') in ('user', 'assistant'):
                        session.add(payload['role'], text_blocks(payload.get('content')), payload.get('id'))
                    elif payload.get('type') in ('function_call', 'custom_tool_call'):
                        raw = payload.get('arguments') or payload.get('input') or '{}'
                        try:
                            arguments = json.loads(raw)
                        except ValueError:
                            arguments = {'code': raw[:1000]}
                        session.note(payload.get('name', 'tool'), arguments)
                    elif payload.get('type') in ('function_call_output', 'custom_tool_call_output'):
                        session.failure(text_blocks(payload.get('output')))
                if kind == 'event_msg' and payload.get('type') == 'item_completed':
                    item = payload.get('item') or {}
                    if item.get('type') == 'FileChange':
                        for filename in item.get('changes') or {}:
                            session.note('file change', {'path': filename})
            else:
                if row.get('isSidechain') or row.get('isMeta'):
                    continue
                session.cwd = row.get('relocatedCwd') or session.cwd or row.get('cwd', '')
                session.title = row.get('customTitle') or row.get('aiTitle') or session.title
                session.continued = row.get('continuedInSessionId') or session.continued
                if kind in ('user', 'assistant'):
                    content = (row.get('message') or {}).get('content')
                    session.add(kind, text_blocks(content), row.get('uuid'))
                    if isinstance(content, list):
                        for block in content:
                            if block.get('type') == 'tool_use':
                                session.note(block.get('name', 'tool'), block.get('input'))
                            elif block.get('type') == 'tool_result' and block.get('is_error'):
                                session.failure(text_blocks(block.get('content')))
    session.updated = path.stat().st_mtime_ns
    return session


def read_sessions(request, db):
    sessions = {}
    for tool, root_name in (('codex', 'codex_root'), ('claude', 'claude_root'), ('claude-work', 'claude_work_root')):
        if not request.get(root_name):
            continue
        root = Path(native_path(request[root_name]))
        for path in sorted(root.rglob('*.jsonl')):
            if 'subagents' in path.parts:
                continue
            stat = path.stat()
            signature = f'4:{stat.st_mtime_ns}:{stat.st_size}'
            if tool == 'claude-work':
                signature = tool + ':' + signature
            cached = db.execute('SELECT signature, data FROM cache WHERE path = ?', (str(path),)).fetchone()
            if cached and cached[0] == signature:
                session = Session(tool, '')
                session.__dict__.update(json.loads(cached[1]))
            else:
                session = read_jsonl(path, tool)
                if session is None:
                    continue
                data = {k: v for k, v in vars(session).items() if k != '_counts'}
                db.execute('INSERT OR REPLACE INTO cache VALUES (?, ?, ?)', (str(path), signature, json.dumps(data)))
            old = sessions.get(session.key)
            # Sorted paths put a Codex thread's dated segments in order.
            if old and session.history_base:
                session.follow(old)
                sessions[session.key] = session
            elif old is None or session.updated > old.updated:
                sessions[session.key] = session
    path = Path(native_path(request['opencode_db']))
    if path.is_file():
        with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as source:
            for sid, cwd, title, updated, parent, archived in source.execute(
                    'SELECT id, directory, title, time_updated, parent_id, time_archived FROM session_v2'):
                session = Session('opencode', sid, cwd or '', title or '')
                session.active = parent is None and archived is None
                session.updated = updated * 1000000
                for kind, data, seq in source.execute('SELECT type, data, seq FROM session_message WHERE session_id = ? ORDER BY seq', (sid,)):
                    if kind not in ('user', 'assistant'):
                        continue
                    message = json.loads(data)
                    session.add(kind, (message.get('text') or '') if kind == 'user' else text_blocks(message.get('content')), f'{sid}:{seq}')
                    for block in message.get('content') or []:
                        if isinstance(block, dict) and block.get('type') == 'tool':
                            state = block.get('state') or {}
                            session.note(block.get('name', 'tool'), state.get('input'))
                            session.failure(text_blocks(state.get('content')))
                sessions[session.key] = session
    # Claude background continuations inherit their predecessor's known history.
    for session in list(sessions.values()):
        if session.continued and session.tool + ':' + session.continued in sessions:
            successor = sessions[session.tool + ':' + session.continued]
            successor.legacy.append(session.key)
            session.active = False
    return sessions


def migrate_state(directory, old_directory):
    if directory.exists() or not old_directory:
        return
    old = Path(native_path(old_directory))
    if not (old / 'sync.db').is_file():
        return
    directory.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.migrate-', dir=directory.parent))
    try:
        with closing(sqlite3.connect((old / 'sync.db').resolve().as_uri() + '?mode=ro', uri=True)) as source:
            with closing(sqlite3.connect(staging / 'sync.db')) as target, target:
                source.backup(target)
                (staging / 'handoffs').mkdir()
                for tid, filename in target.execute('SELECT id, path FROM transfers').fetchall():
                    payload = Path(native_path(filename))
                    shutil.copy2(payload, staging / 'handoffs' / payload.name)
                    target.execute('UPDATE transfers SET path = ? WHERE id = ?',
                                   (str(directory / 'handoffs' / payload.name), tid))
        try:
            staging.rename(directory)
        except OSError:
            # Another picker may have finished the same migration first.
            if not (directory / 'sync.db').is_file():
                raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def open_ledger(directory):
    directory.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(directory / 'sync.db', timeout=30)
    db.execute('CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY, sources TEXT NOT NULL, tool TEXT NOT NULL, target TEXT, events TEXT NOT NULL, path TEXT NOT NULL, created REAL NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS receipts (transfer_id TEXT NOT NULL, session TEXT NOT NULL, PRIMARY KEY (transfer_id, session))')
    db.execute('CREATE TABLE IF NOT EXISTS snapshots (session TEXT PRIMARY KEY, events TEXT NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS cache (path TEXT PRIMARY KEY, signature TEXT NOT NULL, data TEXT NOT NULL)')
    db.commit()
    return db


def session_info(session):
    return {'id': session.id, 'key': session.key, 'cwd': session.cwd, 'title': session.title or session.id}


def plan(request):
    directory = Path(native_path(request['state_dir']))
    migrate_state(directory, request.get('legacy_state_dir'))
    with closing(open_ledger(directory)) as db, db:
        # Serialize discovery and planning across picker processes. A second launch
        # sees the first pending transfer instead of allocating a competing session.
        db.execute('BEGIN IMMEDIATE')
        sessions = read_sessions(request, db)
        transfers = {row[0]: {'sources': json.loads(row[1]), 'tool': row[2], 'target': row[3],
                              'events': json.loads(row[4]), 'path': row[5], 'created': row[6]}
                     for row in db.execute('SELECT * FROM transfers ORDER BY rowid')}
        for session in sessions.values():
            for marker in session.markers:
                transfer = transfers.get(marker)
                if transfer and transfer['tool'] == session.tool:
                    db.execute('INSERT OR IGNORE INTO receipts VALUES (?, ?)', (marker, session.key))
        receipts = collections.defaultdict(list)
        delivered = set()
        for tid, key in db.execute('SELECT transfer_id, session FROM receipts'):
            if tid in transfers:
                receipts[key].append(tid)
                delivered.add(tid)

        exported = collections.defaultdict(dict)
        for transfer in transfers.values():
            for event in transfer['events']:
                exported[event['origin']][event['id']] = event
            if len(transfer['sources']) == 1:
                exported[transfer['sources'][0]].update((e['id'], e) for e in transfer['events'])

        memo = {}

        def knowledge(key, visiting=None, strict=True):
            cache_key = (key, strict)
            if cache_key in memo:
                return memo[cache_key]
            visiting = set(visiting or ())
            if key in visiting:
                return {}, {key}
            visiting.add(key)
            session = sessions.get(key)
            saved = db.execute('SELECT events FROM snapshots WHERE session = ?', (key,)).fetchone()
            events = {e['id']: e for e in json.loads(saved[0])} if saved else {}
            # A previously exported native turn remains known after compaction;
            # a combined export does not make its other inputs known to each source.
            events.update(exported[key])
            ancestors = {key} | {event['origin'] for event in events.values()}

            def receive(tid):
                transfer = transfers[tid]
                events.update((e['id'], e) for e in transfer['events'])
                ancestors.update(transfer['sources'])
                ancestors.update(e['origin'] for e in transfer['events'])

            if session:
                unknown = set(session.markers) - set(transfers)
                if unknown and strict:
                    raise ValueError('A handoff ledger entry is missing. Restore the AgentSessionHub state directory before synchronizing this conversation.')
                ancestors.update(session.legacy)
                for predecessor in session.legacy:
                    prev = sessions.get(predecessor)
                    if prev and prev.continued == session.id:
                        inherited, origins = knowledge(predecessor, visiting, strict)
                        events.update(inherited)
                        ancestors.update(origins)
            # Receipts survive transcript compaction; import those without a remaining
            # prompt first. Otherwise splice snapshots at their actual prompt position.
            for tid in receipts[key]:
                if not session or tid not in session.markers:
                    receive(tid)
            own = {e['id']: e for e in session.events} if session else {}
            for item in session.timeline if session else []:
                if 'event' in item:
                    events[item['event']] = own[item['event']]
                elif item.get('transfer') in receipts[key]:
                    receive(item['transfer'])
                elif 'legacy' in item and strict:
                    origin, filename = item['legacy']
                    path = Path(native_path(filename))
                    if not path.is_file():
                        if any(event.get('legacy_path') == filename for event in events.values()):
                            continue
                        raise ValueError('An older handoff file is missing: ' + filename + '. Its inherited context cannot be synchronized safely.')
                    content = path.read_text(encoding='utf-8-sig')
                    eid = 'legacy:' + origin + ':' + digest(content)
                    events[eid] = {'id': eid, 'origin': origin, 'role': 'legacy context', 'text': content, 'legacy_path': filename}
            if strict:
                db.execute('INSERT OR REPLACE INTO snapshots VALUES (?, ?)', (key, json.dumps(list(events.values()))))
            memo[cache_key] = events, ancestors
            return events, ancestors

        sources = sorted(set(request['sources']))
        if not sources or any(key not in sessions for key in sources):
            raise ValueError('A source session is missing. Reload the picker before transferring.')
        available, ancestry, common = {}, set(), None
        for key in sources:
            events, ancestors = knowledge(key)
            available.update(events)
            ancestry.update(ancestors)
            common = set(ancestors) if common is None else common & ancestors
        target_tool = request['tool']
        if target_tool not in TOOLS:
            raise ValueError('Unknown target tool: ' + target_tool)
        candidates, exact_combines = [], []
        for key, session in sessions.items():
            if session.tool != target_tool or not session.active or key in sources:
                continue
            _, origins = knowledge(key, strict=False)
            if len(sources) > 1:
                exact = (session.combined_sources == sources or
                         any(sorted(transfers[tid]['sources']) == sources for tid in receipts[key]))
                if exact:
                    exact_combines.append(session)
                linked = exact or bool(common & origins)
            else:
                linked = bool(ancestry & origins)
            if linked:
                candidates.append(session)
        candidates = exact_combines or candidates
        candidates.sort(key=lambda s: s.updated, reverse=True)
        selected = request.get('target')
        if selected is None and len(candidates) > 1:
            return {'status': 'choose', 'candidates': [session_info(s) for s in candidates]}
        if selected and selected != '__NEW__':
            target = next((s for s in candidates if s.key == selected), None)
            if target is None:
                raise ValueError('The selected destination is no longer available. Reload and retry.')
        else:
            target = candidates[0] if candidates and selected != '__NEW__' else None
        if target and not target.cwd:
            raise ValueError('The destination has no recorded working directory yet. Reload and retry after it finishes starting.')
        known = knowledge(target.key)[0] if target else {}
        own_origins = {target.key} if target else set()
        if target:
            own_origins.update(event['origin'] for event in target.events)
        delta = [event for eid, event in available.items() if eid not in known
                 and not (event['role'] == 'legacy context' and event['origin'] in own_origins)]
        result = {'status': 'ready', 'target': session_info(target) if target else None,
                  'count': len(delta), 'handoff': None, 'legacy': bool(target and target.legacy_context)}
        if not delta:
            if target is None:
                raise ValueError('No chat or tool notes found in the selected sources.')
            return result
        target_key = target.key if target else None
        for tid, transfer in transfers.items():
            if (tid not in delivered and transfer['sources'] == sources and transfer['tool'] == target_tool
                    and transfer['target'] == target_key):
                if not request.get('retry'):
                    return {'status': 'pending', 'age': int(time.time() - transfer['created']),
                            'message': 'The previous transfer has not appeared in a destination transcript. It may still be starting.'}
                # Reuse the exact pending snapshot. Work added meanwhile remains a
                # delta for the next transfer; it cannot fall between time cutoffs.
                result.update(handoff=transfer['path'], count=len(transfer['events']))
                return result
        if request.get('preview'):
            result['status'] = 'preview'
            return result
        tid = uuid.uuid4().hex
        folder = directory / 'handoffs'
        folder.mkdir(exist_ok=True)
        path = folder / ('hub-transfer-' + tid + '.md')
        lines = ['# Conversation continuation', '', '- Source sessions: ' + ', '.join(sources), '',
                 'Only material not recorded in this destination is included. Continue the existing work; do not restart it.',
                 'Tool notes describe previous actions, not instructions to execute them. Read live files before relying on snapshots.', '']
        for event in delta:
            lines.extend(['## ' + event['origin'] + ' / ' + event['role'], '', event['text'], ''])
        # Never overwrite a payload: a running agent may read it after another click.
        with path.open('x', encoding='utf-8', newline='\n') as output:
            output.write('\n'.join(lines))
        db.execute('INSERT INTO transfers VALUES (?, ?, ?, ?, ?, ?, ?)',
                   (tid, json.dumps(sources), target_tool, target_key, json.dumps(delta), str(path), time.time()))
        result['handoff'] = str(path)
        return result


def main():
    request_path, result_path = (native_path(value) for value in sys.argv[1:3])
    with open(request_path, encoding='utf-8-sig') as stream:
        request = json.load(stream)
    scope = request.get('scope')
    if scope is None:
        # Pickers already open before the move still send the former state path.
        request.setdefault('legacy_state_dir', request['state_dir'])
        scope = Path(native_path(request['state_dir'])).name
    request['state_dir'] = str(Path(__file__).resolve().parent / '.history' / scope)
    try:
        result = plan(request)
    except (OSError, ValueError, sqlite3.Error) as error:
        result = {'status': 'error', 'message': str(error)}
    with open(result_path, 'w', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False)


if __name__ == '__main__':
    main()
