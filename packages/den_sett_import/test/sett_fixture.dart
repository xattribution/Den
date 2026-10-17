import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Builds a small Sett database (schema v12) with one of everything the importer reads.
/// Times are in America/Chicago; October 2026 is CDT (UTC-5).
void writeSettFixture(String path) {
  final db = sqlite3.open(path);
  db.execute('''
CREATE TABLE households (id TEXT PRIMARY KEY, name TEXT NOT NULL, timezone TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE members (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL,
  color TEXT NOT NULL, avatar TEXT NOT NULL, credential_hash TEXT NOT NULL, credential_type TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0, grants_json TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER, ui_level TEXT);
CREATE TABLE events (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT 'family', start_at INTEGER NOT NULL, end_at INTEGER NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0, timezone TEXT NOT NULL, rrule TEXT, created_by TEXT, created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL, deleted_at INTEGER, visibility TEXT NOT NULL DEFAULT 'family', source_sub_id TEXT);
CREATE TABLE event_exceptions (event_id TEXT NOT NULL, occurrence_start INTEGER NOT NULL, kind TEXT NOT NULL, override_json TEXT,
  PRIMARY KEY (event_id, occurrence_start));
CREATE TABLE event_assignees (event_id TEXT NOT NULL, member_id TEXT NOT NULL, PRIMARY KEY (event_id, member_id));
CREATE TABLE tasks (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
  icon TEXT NOT NULL DEFAULT '⭐', kind TEXT NOT NULL, assignee_id TEXT, due_at INTEGER, repeat TEXT, points INTEGER,
  created_by TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER, steps_json TEXT, visibility TEXT NOT NULL DEFAULT 'family');
CREATE TABLE task_completions (task_id TEXT NOT NULL, occurrence_date TEXT NOT NULL DEFAULT '', completed_by TEXT,
  completed_at INTEGER NOT NULL, PRIMARY KEY (task_id, occurrence_date));
CREATE TABLE checklists (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, title TEXT NOT NULL, icon TEXT NOT NULL DEFAULT '🛒',
  kind TEXT NOT NULL DEFAULT 'shopping', pinned_to_dashboard INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, deleted_at INTEGER, need_by INTEGER, linked_event_id TEXT);
CREATE TABLE checklist_items (id TEXT PRIMARY KEY, checklist_id TEXT NOT NULL, text TEXT NOT NULL, checked INTEGER NOT NULL DEFAULT 0,
  checked_by TEXT, checked_at INTEGER, quantity TEXT, sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, store TEXT);
CREATE TABLE reminders (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  offset_minutes INTEGER NOT NULL, target TEXT NOT NULL DEFAULT 'assignees');
CREATE TABLE points_ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, household_id TEXT NOT NULL, member_id TEXT NOT NULL,
  delta INTEGER NOT NULL, reason TEXT NOT NULL, source TEXT NOT NULL, task_id TEXT, occurrence_date TEXT, created_by TEXT, created_at INTEGER NOT NULL);
CREATE TABLE point_goals (id TEXT PRIMARY KEY, household_id TEXT NOT NULL, title TEXT NOT NULL, icon TEXT NOT NULL DEFAULT '🏆',
  mode TEXT NOT NULL, target INTEGER NOT NULL, member_ids_json TEXT, starts_at INTEGER NOT NULL, ends_at INTEGER,
  repeat TEXT NOT NULL DEFAULT 'none', reward TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE TABLE peers (id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE api_tokens (id TEXT PRIMARY KEY, token TEXT NOT NULL, label TEXT NOT NULL, created_at INTEGER NOT NULL, revoked_at INTEGER);
CREATE TABLE device_tokens (id TEXT PRIMARY KEY, label TEXT NOT NULL, created_at INTEGER NOT NULL, revoked_at INTEGER);
CREATE TABLE fed_messages (id TEXT PRIMARY KEY, peer_id TEXT NOT NULL);
CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, summary TEXT NOT NULL);
''');

  // Thursday, October 1, 2026 at 5:00 PM CDT.
  const oct1At5pm = 1790892000000;
  const hour = 3600000;
  const day = 86400000;

  db.execute("INSERT INTO households VALUES ('h1', 'The Rivera family', 'America/Chicago', 0)");
  db.execute("INSERT INTO members VALUES ('m-sam', 'h1', 'Sam', 'parent', '#6f9ccb', '🐻', 'x', 'password', 0, NULL, 0, NULL, NULL)");
  db.execute("INSERT INTO members VALUES ('m-alex', 'h1', 'Alex', 'parent', '#7fb069', '🦊', 'x', 'password', 1, NULL, 0, NULL, NULL)");
  db.execute("INSERT INTO members VALUES ('m-mia', 'h1', 'Mia', 'child', '#d97b72', '🐰', 'x', 'pattern', 2, NULL, 0, NULL, 'little')");
  db.execute("INSERT INTO members VALUES ('m-leo', 'h1', 'Leo', 'child', '#9d8bd0', '🐶', 'x', 'pin', 3, '${jsonEncode(['task.manage'])}', 0, NULL, 'teen')");
  db.execute("INSERT INTO members VALUES ('m-gone', 'h1', 'Old', 'child', '#000000', '🐱', 'x', 'pin', 4, NULL, 0, 5, NULL)");

  db.execute("INSERT INTO events VALUES ('e-soccer', 'h1', 'Soccer practice', 'Bring water', 'Field 4', 'sports', $oct1At5pm, ${oct1At5pm + hour}, 0, 'America/Chicago', 'FREQ=WEEKLY;BYDAY=TU,TH', 'm-sam', 0, 0, NULL, 'family', NULL)");
  db.execute("INSERT INTO event_assignees VALUES ('e-soccer', 'm-leo')");
  db.execute("INSERT INTO reminders VALUES ('r1', 'h1', 'event', 'e-soccer', 60, 'assignees')");
  // October 6 practice canceled, October 8 practice moved to 6 PM.
  db.execute("INSERT INTO event_exceptions VALUES ('e-soccer', ${oct1At5pm + 5 * day}, 'cancelled', NULL)");
  db.execute("INSERT INTO event_exceptions VALUES ('e-soccer', ${oct1At5pm + 7 * day}, 'moved', '${jsonEncode({'startAt': oct1At5pm + 7 * day + hour, 'endAt': oct1At5pm + 7 * day + 2 * hour})}')");
  db.execute("INSERT INTO events VALUES ('e-surprise', 'h1', 'Plan the surprise party', '', '', 'birthday', ${oct1At5pm + 2 * day}, ${oct1At5pm + 2 * day + hour}, 0, 'America/Chicago', NULL, 'm-alex', 0, 0, NULL, 'private', NULL)");
  db.execute("INSERT INTO events VALUES ('e-imported', 'h1', 'Team game', '', '', 'sports', $oct1At5pm, ${oct1At5pm + hour}, 0, 'America/Chicago', NULL, NULL, 0, 0, NULL, 'family', 'sub1')");
  db.execute("INSERT INTO events VALUES ('e-deleted', 'h1', 'Gone', '', '', 'family', $oct1At5pm, ${oct1At5pm + hour}, 0, 'America/Chicago', NULL, NULL, 0, 0, 7, 'family', NULL)");

  db.execute("INSERT INTO tasks VALUES ('t-bed', 'h1', 'Make bed', '', '🛏️', 'chore', 'm-mia', NULL, 'daily', 1, 'm-sam', $oct1At5pm, NULL, NULL, 'family')");
  db.execute("INSERT INTO tasks VALUES ('t-dishes', 'h1', 'Dishes', '', '🍽️', 'chore', 'm-leo', NULL, '1,3,5', 2, 'm-sam', $oct1At5pm, NULL, '${jsonEncode([{'text': 'Load', 'assigneeId': 'm-leo', 'points': 1}, {'text': 'Wipe counters'}])}', 'family')");
  db.execute("INSERT INTO tasks VALUES ('t-trash', 'h1', 'Take out trash', '', '🗑️', 'chore', NULL, ${oct1At5pm + 3 * day}, NULL, 3, 'm-sam', $oct1At5pm, NULL, NULL, 'family')");
  db.execute("INSERT INTO task_completions VALUES ('t-bed', '2026-10-02', 'm-mia', ${oct1At5pm + day})");
  db.execute("INSERT INTO task_completions VALUES ('t-trash', '', 'm-leo', ${oct1At5pm + 3 * day})");

  db.execute("INSERT INTO checklists VALUES ('l-groc', 'h1', 'Groceries', '🛒', 'shopping', 1, 0, 0, NULL, NULL, NULL)");
  db.execute("INSERT INTO checklist_items VALUES ('i1', 'l-groc', 'Milk', 0, NULL, NULL, '2 gal', 0, 0, 'Costco')");
  db.execute("INSERT INTO checklist_items VALUES ('i2', 'l-groc', 'Eggs', 1, 'm-sam', 0, NULL, 1, 0, NULL)");
  db.execute("INSERT INTO checklists VALUES ('l-pack', 'h1', 'Soccer bag', '🎒', 'packing', 0, 1, 0, NULL, NULL, 'e-soccer')");
  db.execute("INSERT INTO checklist_items VALUES ('i3', 'l-pack', 'Shin guards', 0, NULL, NULL, NULL, 0, 0, NULL)");

  db.execute("INSERT INTO points_ledger VALUES (NULL, 'h1', 'm-leo', 5, 'Helped a neighbor', 'manual', NULL, NULL, 'm-sam', 0)");
  db.execute("INSERT INTO points_ledger VALUES (NULL, 'h1', 'm-leo', 2, 'Dishes', 'task', 't-dishes', '2026-10-02', 'm-sam', 0)");
  db.execute("INSERT INTO point_goals VALUES ('g1', 'h1', 'Movie pick', '🏆', 'target', 50, NULL, $oct1At5pm, NULL, 'monthly', 'Pick the movie', 0, NULL)");

  db.execute("INSERT INTO peers VALUES ('p1', 'Grandma')");
  db.execute("INSERT INTO api_tokens VALUES ('a1', 'coord_x', 'HAL', 0, NULL)");
  db.execute("INSERT INTO device_tokens VALUES ('d1', 'Kitchen', 0, NULL)");
  db.execute("INSERT INTO audit_log VALUES (NULL, 'Sam added Milk')");
  db.close();
}
