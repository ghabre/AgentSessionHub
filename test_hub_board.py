import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest

import hub_board


def write_lines(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(record) + '\n' for record in records), encoding='utf-8')


class BoardTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.now = time.time()

    def test_claude_lists_live_sessions_with_running_and_recent_subagents(self):
        home = self.root / '.claude'
        for pid, sid in ((os.getpid(), 'live'), (2 ** 30, 'dead')):
            write_lines(home / 'sessions' / f'{pid}.json', [{'pid': pid, 'sessionId': sid, 'cwd': '/work/proj', 'name': sid + ' title',
                                                             'status': 'busy', 'statusUpdatedAt': self.now * 1000}])
        transcript = home / 'projects' / '-work-proj' / 'live.jsonl'
        write_lines(transcript, [{'type': 'assistant', 'advisorModel': 'claude-opus-5',
                                  'message': {'model': 'claude-fable-5', 'content': [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'ls'}}]}}])
        subagents = transcript.with_suffix('') / 'subagents'
        for name, finished, age in (('run', False, 9000), ('new', True, 10), ('old', True, 9000)):
            write_lines(subagents / f'agent-{name}.meta.json', [{'agentType': 'Explore', 'description': name, 'finished': finished}])
            write_lines(subagents / f'agent-{name}.jsonl', [])
            os.utime(subagents / f'agent-{name}.jsonl', (self.now - age, self.now - age))

        rows = hub_board.claude_rows(home, self.now - 600)

        self.assertEqual([(r.title, r.state, r.project, r.detail, r.model) for r in rows],
                         [('live title', 'busy', 'proj', 'Bash: ls', 'fable-5+opus-5')])
        self.assertEqual(sorted((c.title, c.state) for c in rows[0].children), [('new', 'done'), ('run', 'running')])

    @unittest.skipUnless(os.path.exists('/proc/self/task'), 'shells are read from /proc')
    def test_claude_lists_the_commands_of_its_running_shells(self):
        home = self.root / '.claude'
        write_lines(home / 'sessions' / 'me.json', [{'pid': os.getpid(), 'sessionId': 'live', 'statusUpdatedAt': self.now * 1000}])
        for command in ("eval 'sleep 30; echo '\"'\"'x'\"'\"'' < /dev/null && pwd -P >| /dev/null", 'sleep 30 && true'):
            shell = subprocess.Popen(['bash', '-c', command])
            self.addCleanup(shell.wait)
            self.addCleanup(shell.kill)
        time.sleep(0.2)

        rows = hub_board.claude_rows(home, self.now - 600)

        self.assertEqual([(c.label, c.state, c.title) for c in rows[0].children], [('shell', 'running', "sleep 30; echo 'x'")])

    def test_codex_reads_turn_state_and_attaches_subagents_to_their_parent(self):
        home = self.root / '.codex'
        home.mkdir()
        rollouts = {'top': [{'type': 'session_meta', 'payload': {'id': 'top'}},
                            {'type': 'event_msg', 'timestamp': '2026-01-01T00:00:00Z', 'payload': {'type': 'task_complete'}},
                            {'type': 'event_msg', 'timestamp': '2026-01-01T00:01:00Z', 'payload': {'type': 'task_started'}},
                            {'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'shell', 'arguments': '{"cmd": "make"}'}}],
                    'kid': [{'type': 'session_meta', 'payload': {'id': 'kid', 'parent_thread_id': 'top'}},
                            {'type': 'event_msg', 'timestamp': '2026-01-01T00:02:00Z', 'payload': {'type': 'task_complete'}}]}
        with sqlite3.connect(home / 'state_1.sqlite') as db:
            db.execute('CREATE TABLE threads (id, rollout_path, cwd, source, name, title, first_user_message, agent_role, agent_nickname, '
                       'model, updated_at_ms, archived)')
            for sid, source in (('top', 'cli'), ('kid', '{"subagent": {"other": "guardian"}}')):
                write_lines(home / f'{sid}.jsonl', rollouts[sid])
                db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, 'gpt-5', ?, 0)",
                           (sid, str(home / f'{sid}.jsonl'), '/work/proj', source, sid + ' title', self.now * 1000))

        rows = hub_board.codex_rows(home, self.now - 600)

        self.assertEqual([(r.title, r.state, r.detail, r.model) for r in rows], [('top title', 'working', 'shell: make', 'gpt-5')])
        self.assertEqual([(c.label, c.state) for c in rows[0].children], [('guardian', 'done')])

    def test_opencode_is_working_while_busy_is_newer_than_idle(self):
        database = self.root / 'opencode.db'
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE session_v2 (id, parent_id, directory, title, agent, model, time_updated, time_busy, time_idle, time_archived)')
            recent = self.now * 1000
            db.executemany('INSERT INTO session_v2 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', [
                ('busy', None, '/work/a', 'busy one', 'build', '{"id": "kimi"}', recent, recent, recent - 5, None),
                ('idle', None, '/work/b', 'idle one', 'build', '{"id": "kimi"}', recent, recent - 5, recent, None),
                ('kid', 'busy', '/work/a', 'child', 'explore', '{"id": "kimi"}', recent, recent, recent - 5, None),
                ('stale', None, '/work/c', 'stale', 'build', '{"id": "kimi"}', 1, 1, 2, None),
                ('gone', None, '/work/d', 'archived', 'build', '{"id": "kimi"}', recent, recent, 0, recent)])

        rows = hub_board.opencode_rows(database, self.now - 600)

        self.assertEqual(sorted((r.title, r.state, r.model, len(r.children)) for r in rows),
                         [('busy one', 'working', 'kimi', 1), ('idle one', 'idle', 'kimi', 0)])

    def test_render_nests_subagents_under_their_session(self):
        parent = hub_board.Row('claude', 'proj', 'parent', 'busy', self.now - 90, model='fable-5')
        parent.children.append(hub_board.Row('Explore', '', 'child', 'running', self.now - 5, depth=1))

        lines = hub_board.render([parent], self.now, 200)

        self.assertEqual([line.split() for line in lines[1:]],
                         [['claude', 'proj', 'busy', '1m', 'fable-5', 'parent'], ['\\_', 'Explore', 'running', '5s', 'child']])


if __name__ == '__main__':
    unittest.main()
