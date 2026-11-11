import json
import os
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

import contextlib
import io

from handoff_sync import plan, preview

LINK_SCRIPT = Path(__file__).with_name('claude-accounts.sh')


IDS = {'codex': '11111111-1111-1111-1111-111111111111',
       'claude': '22222222-2222-2222-2222-222222222222', 'opencode': 'ses_test'}


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "space O'Brien"
        self.root.mkdir()
        self.request = {'state_dir': str(self.root / 'state'), 'codex_root': str(self.root / 'codex'),
                        'claude_root': str(self.root / 'claude'), 'opencode_db': str(self.root / 'override.db')}
        with closing(sqlite3.connect(self.request['opencode_db'])) as db, db:
            db.execute('CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, title TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER)')
            db.execute('CREATE TABLE session_message (session_id TEXT, type TEXT, data TEXT, seq INTEGER PRIMARY KEY AUTOINCREMENT)')

    def key(self, tool, sid=None):
        return tool + ':' + (sid or IDS[tool])

    def append(self, tool, text, role='user', sid=None):
        sid = sid or IDS[tool]
        if tool == 'opencode':
            message = {'text': text} if role == 'user' else {'content': [{'type': 'text', 'text': text}]}
            with closing(sqlite3.connect(self.request['opencode_db'])) as db, db:
                db.execute('INSERT OR IGNORE INTO session_v2 VALUES (?, ?, ?, ?, NULL, NULL)', (sid, str(self.root), sid, 1000))
                db.execute('INSERT INTO session_message (session_id, type, data) VALUES (?, ?, ?)', (sid, role, json.dumps(message)))
            return
        folder = Path(self.request[tool + '_root'])
        folder.mkdir(exist_ok=True)
        path = folder / (('rollout-' if tool == 'codex' else '') + sid + '.jsonl')
        rows = []
        if tool == 'codex':
            if not path.exists():
                rows.append({'type': 'session_meta', 'payload': {'id': sid, 'cwd': str(self.root)}})
            rows.append({'type': 'response_item', 'timestamp': '2026-11-05T12:00:00.500Z',
                         'payload': {'type': 'message', 'role': role, 'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}]}})
        else:
            rows.append({'type': role, 'cwd': str(self.root), 'timestamp': '2026-11-05T12:00:00.500Z',
                         'message': {'content': text}})
        with path.open('a', encoding='utf-8') as stream:
            for row in rows:
                stream.write(json.dumps(row) + '\n')

    def transfer(self, sources, tool, **options):
        return plan(dict(self.request, sources=sources, tool=tool, **options))

    def accept(self, result, tool, sid=None):
        self.append(tool, '[Transitioned from Agent; inherited title: Example] Read ' + result['handoff'] + ' -- continue', sid=sid)

    def payload(self, result):
        return Path(result['handoff']).read_text()

    def test_preview_shows_the_last_chat_turns_of_each_tool(self):
        for tool in ('codex', 'claude', 'opencode'):
            for turn in range(10):
                self.append(tool, f'{tool} question {turn}')
            self.append(tool, f'{tool} answer', role='assistant')
            root = self.request['opencode_db' if tool == 'opencode' else tool + '_root']
            with contextlib.redirect_stdout(io.StringIO()) as out:
                preview(tool, root, IDS[tool])
            shown = out.getvalue()
            self.assertIn(f'--- assistant ---\n{tool} answer', shown)
            self.assertIn(f'{tool} question 9', shown)
            self.assertNotIn(f'{tool} question 2', shown)  # only the last 8 turns

    def test_all_six_directions_repeat_and_round_trip(self):
        for source in IDS:
            for target in IDS:
                if source == target:
                    continue
                with self.subTest(source=source, target=target):
                    self.setUp()
                    self.append(source, source + ' original ' + target)
                    result = self.transfer([self.key(source)], target)
                    self.assertEqual('ready', result['status'])
                    if result['handoff']:
                        self.accept(result, target)
                    repeat = self.transfer([self.key(source)], target)
                    self.assertIsNone(repeat['handoff'])
                    self.assertEqual(IDS[target], repeat['target']['id'])
                    self.append(target, target + ' reviewed ' + source, 'assistant')
                    back = self.transfer([self.key(target)], source)
                    self.assertEqual(IDS[source], back['target']['id'])
                    self.assertIn(target + ' reviewed ' + source, self.payload(back))
                    self.assertNotIn(source + ' original ' + target, self.payload(back))
                    self.accept(back, source)

    def test_three_tool_chain_preserves_provenance(self):
        self.append('claude', 'original task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        self.append('codex', 'reviewed implementation', 'assistant')
        second = self.transfer([self.key('codex')], 'opencode')
        self.assertIn('original task', self.payload(second))
        self.assertIn('reviewed implementation', self.payload(second))
        self.accept(second, 'opencode')
        self.append('opencode', 'found a bug', 'assistant')
        back = self.transfer([self.key('opencode')], 'claude')
        self.assertEqual(IDS['claude'], back['target']['id'])
        self.assertNotIn('original task', self.payload(back))
        self.assertIn('found a bug', self.payload(back))
        self.accept(back, 'claude')
        to_codex = self.transfer([self.key('claude')], 'codex')
        self.assertNotIn('reviewed implementation', self.payload(to_codex))
        self.assertIn('found a bug', self.payload(to_codex))

    def test_failed_launch_stays_pending_and_retry_keeps_snapshot(self):
        self.append('claude', 'first')
        first = self.transfer([self.key('claude')], 'codex')
        self.append('claude', 'arrived during launch')
        self.assertEqual('pending', self.transfer([self.key('claude')], 'codex')['status'])
        retry = self.transfer([self.key('claude')], 'codex', retry=True)
        self.assertEqual(first['handoff'], retry['handoff'])
        self.assertNotIn('arrived during launch', self.payload(retry))
        self.accept(retry, 'codex')
        later = self.transfer([self.key('claude')], 'codex')
        self.assertIn('arrived during launch', self.payload(later))
        self.assertNotIn('\nfirst\n', self.payload(later))

    def test_identical_turns_and_same_second_updates_are_not_lost(self):
        self.append('claude', 'repeat')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        self.append('claude', 'repeat')
        second = self.transfer([self.key('claude')], 'codex')
        self.assertEqual(1, second['count'])
        self.accept(second, 'codex')
        self.assertIsNone(self.transfer([self.key('claude')], 'codex')['handoff'])

    def test_repeated_combines_resume_and_update_same_result(self):
        other = '33333333-3333-3333-3333-333333333333'
        self.append('claude', 'thread A')
        self.append('claude', 'thread B', sid=other)
        sources = [self.key('claude'), self.key('claude', other)]
        first = self.transfer(sources, 'codex')
        self.accept(first, 'codex')
        repeat = self.transfer(list(reversed(sources)), 'codex')
        self.assertIsNone(repeat['handoff'])
        self.assertEqual(IDS['codex'], repeat['target']['id'])
        self.append('claude', 'A update')
        update = self.transfer(sources, 'codex')
        self.assertIn('A update', self.payload(update))
        self.assertNotIn('thread B', self.payload(update))
        self.assertNotEqual(first['handoff'], update['handoff'])

    def test_real_branches_require_a_choice(self):
        self.append('claude', 'task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        other = '33333333-3333-3333-3333-333333333333'
        self.accept(first, 'codex', other)
        choices = self.transfer([self.key('claude')], 'codex')
        self.assertEqual('choose', choices['status'])
        self.assertEqual(2, len(choices['candidates']))
        selected = self.transfer([self.key('claude')], 'codex', target=self.key('codex', other))
        self.assertIsNone(selected['handoff'])

    def test_wrong_tool_cannot_acknowledge_a_transfer(self):
        self.append('claude', 'task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'opencode')
        self.assertEqual('pending', self.transfer([self.key('claude')], 'codex')['status'])

    def test_missing_ledger_fails_instead_of_dropping_context(self):
        self.append('claude', 'Read /tmp/hub-transfer-' + 'a' * 32 + '.md')
        with self.assertRaisesRegex(ValueError, 'ledger entry is missing'):
            self.transfer([self.key('claude')], 'codex')

    def test_legacy_round_trip_uses_original_and_preserves_snapshot_forward(self):
        self.append('claude', 'original')
        folder = self.root / 'recent-claude-handoff'
        folder.mkdir()
        path = folder / (IDS['claude'] + '-20261105-120000.md')
        path.write_text('old inherited snapshot')
        self.append('codex', f'[Transitioned from Claude] Read {path} -- continue')
        self.append('codex', 'new review', 'assistant')
        back = self.transfer([self.key('codex')], 'claude')
        self.assertEqual(IDS['claude'], back['target']['id'])
        self.assertNotIn('old inherited snapshot', self.payload(back))
        forward = self.transfer([self.key('codex')], 'opencode')
        self.assertIn('old inherited snapshot', self.payload(forward))

    def test_missing_legacy_payload_is_reported(self):
        path = self.root / 'recent-claude-handoff' / (IDS['claude'] + '-20261105-120000.md')
        self.append('codex', f'Read {path} -- continue')
        with self.assertRaisesRegex(ValueError, 'older handoff file is missing'):
            self.transfer([self.key('codex')], 'opencode')

    def test_preview_cancel_does_not_reserve_a_transfer(self):
        self.append('claude', 'task')
        preview = self.transfer([self.key('claude')], 'codex', preview=True)
        self.assertEqual('preview', preview['status'])
        self.assertFalse((self.root / 'state' / 'handoffs').exists())
        first = self.transfer([self.key('claude')], 'codex')
        self.assertEqual('ready', first['status'])

    def test_concurrent_plans_allocate_only_one_payload(self):
        self.append('claude', 'task')
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.transfer([self.key('claude')], 'codex'), range(2)))
        self.assertEqual(['pending', 'ready'], sorted(r['status'] for r in results))
        self.assertEqual(1, len(list((self.root / 'state' / 'handoffs').glob('*.md'))))

    def test_compacted_destination_keeps_recorded_receipts(self):
        self.append('claude', 'task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        self.transfer([self.key('claude')], 'codex')
        path = Path(self.request['codex_root']) / ('rollout-' + IDS['codex'] + '.jsonl')
        path.unlink()
        self.append('codex', 'compacted summary', 'assistant')
        repeat = self.transfer([self.key('claude')], 'codex')
        self.assertIsNone(repeat['handoff'])
        self.assertEqual(IDS['codex'], repeat['target']['id'])

    def test_compacted_source_keeps_previously_exported_native_turns(self):
        self.append('claude', 'original task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        path = Path(self.request['claude_root']) / (IDS['claude'] + '.jsonl')
        path.unlink()
        self.append('claude', 'summary', 'assistant')
        forward = self.transfer([self.key('claude')], 'opencode')
        self.assertIn('original task', self.payload(forward))
        self.assertIn('summary', self.payload(forward))

    def test_paginated_codex_segment_keeps_earlier_segment_turns(self):
        self.append('codex', 'earlier segment work')
        segment = Path(self.request['codex_root']) / ('rollout-later-' + IDS['codex'] + '.jsonl')
        rows = [{'type': 'session_meta', 'payload': {'id': IDS['codex'], 'cwd': str(self.root), 'history_base': {'thread_id': IDS['codex']}}},
                {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'later segment work'}]}}]
        segment.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        payload = self.payload(self.transfer([self.key('codex')], 'claude'))
        self.assertLess(payload.index('earlier segment work'), payload.index('later segment work'))

    def test_unrelated_missing_legacy_file_does_not_block_transfer(self):
        self.append('claude', 'task')
        self.append('codex', 'Read /tmp/recent-claude-handoff/99999999-9999-9999-9999-999999999999-20261105-120000.md -- continue')
        result = self.transfer([self.key('claude')], 'codex')
        self.assertEqual('ready', result['status'])
        self.assertIsNone(result['target'])

    def test_native_source_files_are_never_modified(self):
        self.append('claude', 'task')
        self.append('codex', 'unrelated task')
        files = list(Path(self.request['claude_root']).glob('*.jsonl')) + list(Path(self.request['codex_root']).glob('*.jsonl'))
        before = {path: path.read_bytes() for path in files}
        self.transfer([self.key('claude')], 'codex')
        self.assertEqual(before, {path: path.read_bytes() for path in files})

    def test_inherited_history_precedes_its_review_when_forwarded(self):
        self.append('claude', 'original task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        self.append('codex', 'later review', 'assistant')
        forward = self.transfer([self.key('codex')], 'opencode')
        body = self.payload(forward)
        self.assertLess(body.index('original task'), body.index('later review'))

    def test_claude_background_continuation_reuses_active_successor(self):
        self.append('claude', 'original task')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        successor = '33333333-3333-3333-3333-333333333333'
        path = Path(self.request['claude_root']) / (IDS['claude'] + '.jsonl')
        with path.open('a') as stream:
            stream.write(json.dumps({'continuedInSessionId': successor}) + '\n')
        self.append('claude', 'continued work', sid=successor)
        self.append('codex', 'review', 'assistant')
        back = self.transfer([self.key('codex')], 'claude')
        self.assertEqual(successor, back['target']['id'])
        self.assertNotIn('original task', self.payload(back))

    def test_legacy_snapshot_survives_after_first_managed_transfer(self):
        self.append('claude', 'original')
        folder = self.root / 'recent-claude-handoff'
        folder.mkdir()
        path = folder / (IDS['claude'] + '-20261105-120000.md')
        path.write_text('inherited original snapshot')
        self.append('codex', f'Read {path} -- continue')
        self.append('codex', 'review', 'assistant')
        back = self.transfer([self.key('codex')], 'claude')
        self.accept(back, 'claude')
        path.unlink()
        forward = self.transfer([self.key('codex')], 'opencode')
        self.assertIn('inherited original snapshot', self.payload(forward))

    def test_legacy_combined_destination_is_reused(self):
        other = '33333333-3333-3333-3333-333333333333'
        self.append('claude', 'thread A')
        self.append('claude', 'thread B', sid=other)
        folder = self.root / 'recent-claude-handoff'
        folder.mkdir()
        path = folder / 'combined-20261105-120000.md'
        path.write_text(f'- Session id: `{IDS["claude"]}`\n- Session id: `{other}`\nOld combined snapshot')
        self.append('codex', f'Read {path} -- combined handoff')
        result = self.transfer([self.key('claude'), self.key('claude', other)], 'codex')
        self.assertEqual(IDS['codex'], result['target']['id'])
        self.assertTrue(result['legacy'])

    def test_combining_reviews_of_one_origin_returns_to_that_origin(self):
        self.append('codex', 'shared task')
        first = self.transfer([self.key('codex')], 'claude')
        self.accept(first, 'claude')
        other = '33333333-3333-3333-3333-333333333333'
        self.accept(first, 'claude', other)
        self.append('claude', 'review A', 'assistant')
        self.append('claude', 'review B', 'assistant', other)
        combined = self.transfer([self.key('claude'), self.key('claude', other)], 'codex')
        self.assertEqual(IDS['codex'], combined['target']['id'])
        self.assertNotIn('shared task', self.payload(combined))
        self.assertIn('review A', self.payload(combined))
        self.assertIn('review B', self.payload(combined))

    def test_fork_inherits_updates_sent_to_its_predecessor(self):
        self.append('claude', 'original')
        first = self.transfer([self.key('claude')], 'codex')
        self.accept(first, 'codex')
        self.append('claude', 'additional source context')
        update = self.transfer([self.key('claude')], 'codex')
        self.accept(update, 'codex')
        fork = '33333333-3333-3333-3333-333333333333'
        self.accept(first, 'codex', fork)
        self.accept(update, 'codex', fork)
        forward = self.transfer([self.key('codex', fork)], 'opencode')
        self.assertIn('additional source context', self.payload(forward))

    def test_moving_history_preserves_receipts_payloads_and_pending_retry(self):
        self.append('claude', 'original')
        first = self.transfer([self.key('claude')], 'codex')
        old_directory = self.request['state_dir']
        old_payload = Path(first['handoff'])
        self.request['state_dir'] = str(self.root / '.history' / 'sync-windows')
        self.request['legacy_state_dir'] = old_directory
        retry = self.transfer([self.key('claude')], 'codex', retry=True)
        self.assertNotEqual(first['handoff'], retry['handoff'])
        self.assertEqual(old_payload.read_bytes(), Path(retry['handoff']).read_bytes())
        self.assertTrue(old_payload.is_file())
        self.assertTrue((Path(old_directory) / 'sync.db').is_file())
        # A prompt already queued with its old path still acknowledges the same UUID.
        self.accept(first, 'codex')
        self.assertIsNone(self.transfer([self.key('claude')], 'codex')['handoff'])
        self.append('claude', 'new work')
        next_transfer = self.transfer([self.key('claude')], 'codex')
        self.accept(next_transfer, 'codex')
        # Subsequent runs must not replace the new ledger with the older copy.
        self.assertIsNone(self.transfer([self.key('claude')], 'codex')['handoff'])



@unittest.skipUnless(shutil.which('bash') and os.name != 'nt', 'needs Linux bash symlinks')
class LinkAccountTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.shared = self.root / '.claude'
        (self.shared / 'projects' / 'p').mkdir(parents=True)
        (self.shared / 'projects' / 'p' / 'shared.jsonl').write_text('shared')
        (self.shared / 'settings.json').write_text('shared settings')
        self.account = self.root / ".claude-work O'Brien"
        (self.account / 'projects' / 'old').mkdir(parents=True)
        (self.account / 'projects' / 'old' / 'own.jsonl').write_text('own')
        (self.account / 'settings.json').write_text('own settings')
        (self.account / '.credentials.json').write_text('login')
        (self.account / '.claude.json').write_text('{"oauthAccount": {"emailAddress": "work@example.com"}}')

    def tearDown(self):
        self.tmp.cleanup()

    def link(self, *args):
        result = subprocess.run(['bash', str(LINK_SCRIPT), str(self.shared), *args],
                                capture_output=True, text=True, check=True)
        lines = result.stdout.splitlines()
        self.accounts = [line[8:].split('\t') for line in lines if line.startswith('ACCOUNT:')]
        return [line for line in lines if not line.startswith('ACCOUNT:')]

    def test_links_history_keeps_login_and_sets_aside_without_deleting(self):
        out = self.link()
        self.assertEqual('shared', (self.account / 'projects' / 'p' / 'shared.jsonl').read_text())
        self.assertTrue((self.account / 'sessions').is_symlink())
        self.assertEqual('login', (self.account / '.credentials.json').read_text())
        self.assertFalse((self.account / '.credentials.json').is_symlink())
        self.assertFalse((self.account / '.claude.json').is_symlink())
        aside = [Path(line.split(':', 1)[1]) for line in out if line.startswith('SET_ASIDE:')]
        self.assertEqual({'projects', 'settings.json'}, {p.name.split('.pre-shared-')[0] for p in aside})
        own = next(p for p in aside if p.name.startswith('projects'))
        self.assertEqual('own', (own / 'old' / 'own.jsonl').read_text())
        self.assertEqual([], self.link())  # idempotent

    def test_lists_accounts_with_emails_and_appends_new_numbered_ones(self):
        (self.root / '.claude-10').mkdir()
        (self.root / '.claude.json').write_text('{"oauthAccount": {"emailAddress": "first@example.com"}}')
        self.link('new')
        self.assertEqual([[str(self.shared), 'first@example.com'], [str(self.account), 'work@example.com'],
                          [str(self.root / '.claude-2'), ''], [str(self.root / '.claude-10'), '']], self.accounts)
        self.assertTrue((self.root / '.claude-2' / 'projects').is_symlink())

    def test_account_with_live_session_is_left_alone(self):
        (self.account / 'sessions').mkdir()
        (self.account / 'sessions' / f'{os.getpid()}.json').write_text('{}')
        self.assertEqual([f'LIVE:{self.account}'], self.link())
        self.assertFalse((self.account / 'projects').is_symlink())


if __name__ == '__main__':
    unittest.main()
