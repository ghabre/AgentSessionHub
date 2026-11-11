import json
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

from handoff_sync import plan


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

    def test_duplicate_claude_ids_keep_profile_keys_and_cached_events_separate(self):
        self.request['claude_work_root'] = str(self.root / 'work')
        self.append('claude', 'personal task')
        work = Path(self.request['claude_work_root'])
        work.mkdir()
        # A literal copied transcript includes the same native message UUID.
        personal = Path(self.request['claude_root']) / (IDS['claude'] + '.jsonl')
        row = json.loads(personal.read_text())
        row['uuid'] = 'same-native-message'
        personal.write_text(json.dumps(row) + '\n')
        (work / personal.name).write_bytes(personal.read_bytes())
        first = self.transfer([self.key('claude')], 'codex')
        other = self.transfer(['claude-work:' + IDS['claude']], 'codex')
        self.assertEqual('ready', other['status'])
        self.assertIn('claude-work:' + IDS['claude'], self.payload(other))
        self.assertNotEqual(first['handoff'], other['handoff'])
        with sqlite3.connect(self.request['state_dir'] + '/sync.db') as db:
            cached = [json.loads(row[0]) for row in db.execute('SELECT data FROM cache')]
        sessions = {s['key']: s for s in cached if s['id'] == IDS['claude']}
        self.assertEqual({'claude:' + IDS['claude'], 'claude-work:' + IDS['claude']}, set(sessions))
        events = [s['events'][0]['id'] for s in sessions.values()]
        self.assertEqual(2, len(set(events)))

    def test_claude_receipts_and_resume_targets_stay_in_selected_profile(self):
        self.request['claude_work_root'] = str(self.root / 'work')
        self.append('codex', 'task')
        first = self.transfer([self.key('codex')], 'claude')
        self.accept(first, 'claude')
        work = Path(self.request['claude_work_root'])
        work.mkdir()
        personal = Path(self.request['claude_root']) / (IDS['claude'] + '.jsonl')
        (work / personal.name).write_bytes(personal.read_bytes())
        result = self.transfer([self.key('codex')], 'claude-work')
        self.assertEqual('ready', result['status'])
        self.assertIsNone(result['target'])
        self.assertIsNotNone(result['handoff'])
        row = {'type': 'user', 'cwd': str(self.root), 'message': {'content': 'Read ' + result['handoff']}}
        with (work / personal.name).open('a') as stream:
            stream.write(json.dumps(row) + '\n')
        repeat = self.transfer([self.key('codex')], 'claude-work')
        self.assertEqual('claude-work:' + IDS['claude'], repeat['target']['key'])
        self.assertIsNone(repeat['handoff'])
        personal_repeat = self.transfer([self.key('codex')], 'claude')
        self.assertEqual(self.key('claude'), personal_repeat['target']['key'])
        self.assertIsNone(personal_repeat['handoff'])

    def test_work_background_continuation_does_not_link_personal_successor(self):
        self.request['claude_work_root'] = str(self.root / 'work')
        successor = '33333333-3333-3333-3333-333333333333'
        self.append('claude', 'personal successor', sid=successor)
        work = Path(self.request['claude_work_root'])
        work.mkdir()
        row = {'type': 'user', 'cwd': str(self.root), 'continuedInSessionId': successor,
               'message': {'content': 'work predecessor'}}
        (work / (IDS['claude'] + '.jsonl')).write_text(json.dumps(row) + '\n')
        result = self.transfer(['claude-work:' + IDS['claude']], 'claude')
        self.assertIsNone(result['target'])
        self.assertIn('work predecessor', self.payload(result))

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


if __name__ == '__main__':
    unittest.main()
