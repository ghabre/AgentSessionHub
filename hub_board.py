"""Live, read-only board of running agent sessions, their subagents and their shells.

Claude sessions are live while their recorded process exists. Codex and OpenCode keep no
process record, so a session counts as active while it is busy or was updated recently.
"""
import argparse
import glob
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import time


class Row:
    def __init__(self, label, project, title, state, since, detail='', depth=0, model=''):
        self.label, self.project, self.title, self.state = label, project, title, state
        self.since, self.detail, self.depth, self.model = since, detail, depth, model
        self.children = []


def alive(pid):
    if sys.platform != 'win32':
        return os.path.exists(f'/proc/{pid}')
    import ctypes
    # os.kill(pid, 0) would send CTRL_C_EVENT on Windows; only ask whether the process can be opened.
    handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    if handle:
        ctypes.windll.kernel32.CloseHandle(handle)
    return bool(handle)


def tail_records(path, size=200_000):
    """JSON records from the end of a transcript, oldest first; a cut-off first line is dropped."""
    with open(path, 'rb') as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell() - size))
        lines = stream.read().decode('utf-8', 'replace').splitlines()
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


def brief(name, arguments):
    if not isinstance(arguments, dict):
        return name
    value = next((arguments[k] for k in ('description', 'command', 'cmd', 'file_path', 'path', 'pattern', 'query', 'url') if arguments.get(k)), '')
    return f'{name}: {value}' if value else name


def one_line(text):
    return ' '.join(str(text or '').split())


def claude_turn(path):
    """(model, detail) of the newest assistant turn; an advisor model follows the turn's own after a +."""
    for record in reversed(tail_records(path)):
        message = record.get('message') or {}
        content = message.get('content')
        if record.get('type') != 'assistant' or not isinstance(content, list) or message.get('model') == '<synthetic>':
            continue
        model = '+'.join(name.replace('claude-', '') for name in (message.get('model'), record.get('advisorModel')) if name)
        for block in reversed(content):
            if block.get('type') == 'tool_use':
                return model, brief(block.get('name', 'tool'), block.get('input'))
            if block.get('type') == 'text' and block.get('text', '').strip():
                return model, one_line(block['text'])
    return '', ''


def claude_shells(pid):
    """Rows for the shells a Claude process is running, read from /proc, so Linux only."""
    rows = []
    for children in glob.glob(f'/proc/{pid}/task/*/children'):
        for child in Path(children).read_text().split():
            try:
                command = Path(f'/proc/{child}/cmdline').read_bytes().replace(b'\0', b' ').decode('utf-8', 'replace')
                started = os.path.getmtime(f'/proc/{child}')
            except OSError:
                continue  # It exited while being read.
            # Claude runs a command as: <shell setup> && eval '<command>' [< /dev/null] && pwd -P >| <file>
            wrapped = re.search(r"eval '(.*)' (?:< /dev/null )?&& pwd -P", command, re.DOTALL)
            if wrapped:
                rows.append(Row('shell', '', one_line(wrapped.group(1).replace("'\"'\"'", "'")), 'running', started, depth=1))
    return rows


def claude_rows(home, cutoff):
    rows = []
    for path in glob.glob(str(home / 'sessions' / '*.json')):
        try:
            session = json.loads(Path(path).read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue  # Claude rewrites these records while it runs.
        if not session.get('sessionId') or not alive(session.get('pid', 0)):
            continue
        cwd = session.get('cwd', '')
        row = Row('claude', Path(cwd).name, session.get('name') or '', session.get('status') or '?',
                  (session.get('statusUpdatedAt') or session.get('updatedAt') or 0) / 1000)
        transcripts = glob.glob(str(home / 'projects' / '*' / (session['sessionId'] + '.jsonl')))
        row.children = claude_shells(session['pid'])
        if transcripts:
            row.model, row.detail = claude_turn(transcripts[0])
            for meta_path in glob.glob(transcripts[0][:-len('.jsonl')] + '/subagents/agent-*.meta.json'):
                try:
                    meta = json.loads(Path(meta_path).read_text(encoding='utf-8'))
                except (OSError, ValueError):
                    continue
                transcript = meta_path[:-len('.meta.json')] + '.jsonl'
                started = os.path.exists(transcript)
                updated = os.path.getmtime(transcript if started else meta_path)
                if meta.get('finished') and updated < cutoff:
                    continue
                model, detail = claude_turn(transcript) if started else ('', '')
                row.children.append(Row(meta.get('agentType') or 'agent', '', meta.get('description') or '',
                                        'done' if meta.get('finished') else 'running', updated,
                                        '' if meta.get('finished') else detail, meta.get('spawnDepth') or 1, model))
        rows.append(row)
    return rows


def codex_turn(path):
    """(state, since, detail) from the end of a rollout; turns are bracketed by task_started/task_complete."""
    state, since, detail = 'idle', None, ''
    for record in tail_records(path):
        payload = record.get('payload') or {}
        kind = payload.get('type')
        if record.get('type') == 'event_msg' and kind in ('task_started', 'task_complete'):
            state, since = ('working' if kind == 'task_started' else 'idle'), record.get('timestamp')
        elif record.get('type') == 'response_item' and kind in ('function_call', 'custom_tool_call'):
            raw = payload.get('arguments') or payload.get('input') or ''
            try:
                detail = brief(payload.get('name', 'tool'), json.loads(raw))
            except (ValueError, TypeError):
                detail = f"{payload.get('name', 'tool')}: {one_line(raw)}"
    return state, since, detail


def iso_seconds(stamp):
    return time.mktime(time.strptime(stamp[:19], '%Y-%m-%dT%H:%M:%S')) - time.timezone if stamp else None


def codex_rows(home, cutoff):
    databases = glob.glob(str(home / 'state_*.sqlite'))
    if not databases:
        return []
    tops, children = {}, []
    with sqlite3.connect(Path(max(databases, key=os.path.getmtime)).as_uri() + '?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        threads = db.execute('SELECT id, rollout_path, cwd, source, name, title, first_user_message, agent_role, agent_nickname, model, updated_at_ms '
                             'FROM threads WHERE archived = 0 AND updated_at_ms >= ?', (int(cutoff * 1000),)).fetchall()
    for thread in threads:
        if not thread['rollout_path'] or not os.path.exists(thread['rollout_path']):
            continue
        state, since, detail = codex_turn(thread['rollout_path'])
        since = iso_seconds(since) or thread['updated_at_ms'] / 1000
        if thread['source'].startswith('{'):  # {"subagent": ...}: the parent is named only in the rollout's first record.
            with open(thread['rollout_path'], encoding='utf-8', errors='replace') as stream:
                parent = (json.loads(stream.readline()).get('payload') or {}).get('parent_thread_id')
            label = thread['agent_role'] or thread['agent_nickname'] or next(iter((json.loads(thread['source']).get('subagent') or {}).values()), 'agent')
            children.append((parent, Row(str(label), '', one_line(thread['title'] or thread['first_user_message']),
                                         'running' if state == 'working' else 'done', since, detail, 1, thread['model'] or '')))
        else:
            tops[thread['id']] = Row('codex', Path(thread['cwd']).name, one_line(thread['name'] or thread['title'] or thread['first_user_message']),
                                     state, since, detail, model=thread['model'] or '')
    for parent, child in children:
        if parent in tops:
            tops[parent].children.append(child)
    return list(tops.values())


def opencode_rows(database, cutoff):
    if not database.is_file():
        return []
    tops, children = {}, []
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
        sessions = db.execute('SELECT id, parent_id, directory, title, agent, model, time_updated, time_busy, time_idle FROM session_v2 '
                              'WHERE time_archived IS NULL AND time_updated >= ?', (int(cutoff * 1000),)).fetchall()
    for sid, parent, directory, title, agent, model, updated, busy, idle in sessions:
        working = (busy or 0) > (idle or 0)
        since = (busy if working else idle or updated) / 1000
        model = json.loads(model)['id'] if model else ''
        if parent:
            children.append((parent, Row(agent or 'agent', '', one_line(title), 'running' if working else 'done', since, depth=1, model=model)))
        else:
            tops[sid] = Row('opencode', Path(directory or '').name, one_line(title), 'working' if working else 'idle', since, model=model)
    for parent, child in children:
        if parent in tops:
            tops[parent].children.append(child)
    return list(tops.values())


def age(since, now):
    seconds = max(0, int(now - since))
    for unit, size in (('d', 86400), ('h', 3600), ('m', 60)):
        if seconds >= size:
            return f'{seconds // size}{unit}'
    return f'{seconds}s'


def render(rows, now, width):
    lines = [f"{'agent':<10}{'project':<20}{'state':<9}{'for':<5}{'model':<21}title / last action"]
    for row in sorted(rows, key=lambda r: -r.since):
        for item in [row] + sorted(row.children, key=lambda r: -r.since):
            # A subagent or shell has no project of its own; its type goes in that column under the parent.
            agent, project = (item.label, item.project) if item is row else ('  ' * item.depth + '\\_', item.label)
            text = item.title + (f'  [{one_line(item.detail)}]' if item.detail else '')
            lines.append(f'{agent:<10.9}{project:<20.19}{item.state:<9.8}{age(item.since, now):<5}{item.model:<21.20}{text}'[:width])
    return lines if rows else lines + ['no active sessions']


def collect(minutes):
    home = Path.home()
    cutoff = time.time() - minutes * 60
    data = Path(os.environ.get('XDG_DATA_HOME') or home / '.local' / 'share') / 'opencode'
    database = data / os.environ.get('OPENCODE_DB', 'opencode.db')  # An absolute OPENCODE_DB replaces the folder.
    return claude_rows(home / '.claude', cutoff) + codex_rows(home / '.codex', cutoff) + opencode_rows(database, cutoff)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--minutes', type=int, default=30, help='how long a Codex/OpenCode session or a finished subagent stays listed')
    parser.add_argument('--interval', type=float, default=3, help='seconds between refreshes')
    parser.add_argument('--once', action='store_true', help='print one snapshot and exit')
    options = parser.parse_args()
    while True:
        lines = render(collect(options.minutes), time.time(), shutil.get_terminal_size((160, 40)).columns)
        if options.once:
            print('\n'.join(lines))
            return
        # Home the cursor and clear below it, so a refresh never scrolls the tab.
        sys.stdout.write('\x1b[H\x1b[J' + '\n'.join(lines) + '\n')
        sys.stdout.flush()
        time.sleep(options.interval)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
