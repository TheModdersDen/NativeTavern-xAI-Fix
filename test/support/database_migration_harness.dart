import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// A database schema and data seed captured from an older app release.
class LegacyDatabaseFixture {
  const LegacyDatabaseFixture({
    required this.schemaVersion,
    required this.schemaStatements,
    required this.seedStatements,
  });

  final int schemaVersion;
  final List<String> schemaStatements;
  final List<String> seedStatements;

  void writeTo(File file) {
    if (file.existsSync()) file.deleteSync();
    file.parent.createSync(recursive: true);

    final database = sqlite.sqlite3.open(file.path);
    try {
      database.execute('PRAGMA foreign_keys = OFF');
      database.execute('BEGIN');
      for (final statement in schemaStatements) {
        database.execute(statement);
      }
      for (final statement in seedStatements) {
        database.execute(statement);
      }
      database.execute('PRAGMA user_version = $schemaVersion');
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    } finally {
      database.dispose();
    }
  }
}

/// Historical fixtures derived from committed versions of database.dart.
abstract final class LegacyDatabaseFixtures {
  static const v10 = LegacyDatabaseFixture(
    schemaVersion: 10,
    schemaStatements: _v10SchemaStatements,
    seedStatements: _representativeLegacySeedStatements,
  );

  static const v13 = LegacyDatabaseFixture(
    schemaVersion: 13,
    schemaStatements: _v13SchemaStatements,
    seedStatements: [
      ..._representativeLegacySeedStatements,
      ..._v13SeedStatements,
    ],
  );

  /// Models an interrupted v10-to-v11 upgrade: the second v11 column exists,
  /// while the first and third do not. Production migration must fail and
  /// roll back instead of advancing user_version or leaving another column.
  static const interruptedV10 = LegacyDatabaseFixture(
    schemaVersion: 10,
    schemaStatements: [
      ..._v10SchemaStatements,
      '''
        ALTER TABLE world_info_entries
        ADD COLUMN automation_id TEXT NOT NULL DEFAULT ''
      ''',
    ],
    seedStatements: _representativeLegacySeedStatements,
  );
}

class MigrationTestHarness {
  MigrationTestHarness._(this.directory);

  final Directory directory;
  final List<AppDatabase> _openDatabases = [];

  static MigrationTestHarness create() {
    return MigrationTestHarness._(
      Directory.systemTemp.createTempSync('native_tavern_migration_'),
    );
  }

  File createFixture(
    LegacyDatabaseFixture fixture, {
    String? name,
  }) {
    final file = File(
      '${directory.path}/${name ?? 'schema_v${fixture.schemaVersion}'}.sqlite',
    );
    fixture.writeTo(file);
    return file;
  }

  AppDatabase openWithProductionMigrations(File file) {
    final database = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (rawDatabase) {
          rawDatabase.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    _openDatabases.add(database);
    return database;
  }

  AppDatabase createCurrentDatabase({String? name}) {
    final file = File('${directory.path}/${name ?? 'current'}.sqlite');
    return openWithProductionMigrations(file);
  }

  Future<void> close(AppDatabase database) async {
    if (_openDatabases.remove(database)) {
      await database.close();
    }
  }

  Future<void> dispose() async {
    for (final database in _openDatabases.reversed.toList()) {
      await database.close();
    }
    _openDatabases.clear();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}

class SnapshotTable {
  const SnapshotTable(
    this.name, {
    required this.orderBy,
    this.columns = const [],
  });

  final String name;
  final List<String> orderBy;
  final List<String> columns;

  String get selectSql {
    final selected =
        columns.isEmpty ? '*' : columns.map(_quoteIdentifier).join(', ');
    final ordering = orderBy.map(_quoteIdentifier).join(', ');
    return 'SELECT $selected FROM ${_quoteIdentifier(name)} '
        'ORDER BY $ordering';
  }
}

class LogicalDatabaseSnapshot {
  const LogicalDatabaseSnapshot(this.tables);

  final Map<String, List<Map<String, Object?>>> tables;
}

Future<LogicalDatabaseSnapshot> captureDatabaseSnapshot(
  AppDatabase database,
  Iterable<SnapshotTable> tables,
) async {
  final snapshot = <String, List<Map<String, Object?>>>{};
  for (final table in tables) {
    final rows = await database.customSelect(table.selectSql).get();
    snapshot[table.name] =
        rows.map((row) => _normalizeRow(row.data)).toList(growable: false);
  }
  return LogicalDatabaseSnapshot(snapshot);
}

LogicalDatabaseSnapshot captureRawDatabaseSnapshot(
  File file,
  Iterable<SnapshotTable> tables,
) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    final snapshot = <String, List<Map<String, Object?>>>{};
    for (final table in tables) {
      final rows = database.select(table.selectSql);
      snapshot[table.name] = rows
          .map((row) => _normalizeRow(Map<String, Object?>.from(row)))
          .toList(growable: false);
    }
    return LogicalDatabaseSnapshot(snapshot);
  } finally {
    database.dispose();
  }
}

Future<int> readSchemaVersion(AppDatabase database) async {
  final row = await database.customSelect('PRAGMA user_version').getSingle();
  return row.data.values.single as int;
}

int readRawSchemaVersion(File file) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return database.userVersion;
  } finally {
    database.dispose();
  }
}

Set<String> readRawTableColumns(File file, String tableName) {
  final database =
      sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    return database
        .select('PRAGMA table_info(${_quoteIdentifier(tableName)})')
        .map((row) => row['name'] as String)
        .toSet();
  } finally {
    database.dispose();
  }
}

Future<Set<String>> readTableNames(AppDatabase database) async {
  final rows = await database.customSelect('''
    SELECT name FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    ORDER BY name
  ''').get();
  return rows.map((row) => row.read<String>('name')).toSet();
}

Future<String> runIntegrityCheck(AppDatabase database) async {
  final row = await database.customSelect('PRAGMA integrity_check').getSingle();
  return row.data.values.single as String;
}

Future<List<Map<String, Object?>>> findForeignKeyViolations(
  AppDatabase database,
) async {
  final rows = await database.customSelect('PRAGMA foreign_key_check').get();
  return rows.map((row) => _normalizeRow(row.data)).toList(growable: false);
}

Future<void> seedCurrentRepresentativeData(AppDatabase database) async {
  for (final statement in _representativeLegacySeedStatements) {
    await database.customStatement(statement);
  }
  for (final statement in _currentOnlySeedStatements) {
    await database.customStatement(statement);
  }
}

const currentSnapshotTables = <SnapshotTable>[
  SnapshotTable('characters', orderBy: ['id']),
  SnapshotTable('chats', orderBy: ['id']),
  SnapshotTable('messages', orderBy: ['id']),
  SnapshotTable('world_infos', orderBy: ['id']),
  SnapshotTable('world_info_entries', orderBy: ['id']),
  SnapshotTable('llm_configs', orderBy: ['id']),
  SnapshotTable('personas', orderBy: ['id']),
  SnapshotTable('groups', orderBy: ['id']),
  SnapshotTable('bookmarks', orderBy: ['id']),
  SnapshotTable('tags', orderBy: ['id']),
  SnapshotTable('character_tags', orderBy: ['character_id', 'tag_id']),
  SnapshotTable('global_states', orderBy: ['key']),
];

const legacyV10PreservedSnapshotTables = <SnapshotTable>[
  SnapshotTable(
    'characters',
    orderBy: ['id'],
    columns: [
      'id',
      'name',
      'alternate_greetings',
      'assets_json',
      'character_book_json',
      'extensions_json',
      'tags',
      'is_favorite',
    ],
  ),
  SnapshotTable(
    'chats',
    orderBy: ['id'],
    columns: [
      'id',
      'character_id',
      'settings_json',
      'author_note',
      'author_note_depth',
      'author_note_enabled',
    ],
  ),
  SnapshotTable(
    'messages',
    orderBy: ['id'],
    columns: [
      'id',
      'chat_id',
      'content',
      'swipes',
      'metadata_json',
      'attachments_json',
    ],
  ),
  SnapshotTable(
    'world_infos',
    orderBy: ['id'],
    columns: ['id', 'name', 'character_id'],
  ),
  SnapshotTable(
    'world_info_entries',
    orderBy: ['id'],
    columns: [
      'id',
      'world_info_id',
      'keys',
      'secondary_keys',
      'content',
      'extensions_json',
    ],
  ),
  SnapshotTable(
    'personas',
    orderBy: ['id'],
    columns: ['id', 'name', 'description', 'is_default'],
  ),
  SnapshotTable(
    'groups',
    orderBy: ['id'],
    columns: ['id', 'members_json', 'settings_json'],
  ),
  SnapshotTable(
    'bookmarks',
    orderBy: ['id'],
    columns: ['id', 'chat_id', 'message_id', 'message_index'],
  ),
  SnapshotTable(
    'character_tags',
    orderBy: ['character_id', 'tag_id'],
  ),
];

const legacyV13PreservedSnapshotTables = <SnapshotTable>[
  ...legacyV10PreservedSnapshotTables,
  SnapshotTable(
    'world_infos',
    orderBy: ['id'],
    columns: [
      'id',
      'name',
      'character_id',
      'scan_depth',
      'case_sensitive',
      'match_whole_words',
      'use_group_scoring',
      'recursion_depth',
      'extensions_json',
    ],
  ),
  SnapshotTable(
    'world_info_entries',
    orderBy: ['id'],
    columns: [
      'id',
      'world_info_id',
      'keys',
      'secondary_keys',
      'content',
      'use_group_scoring',
      'automation_id',
      'delay_until_recursion',
      'extensions_json',
    ],
  ),
  SnapshotTable('global_states', orderBy: ['key']),
];

Map<String, Object?> _normalizeRow(Map<String, Object?> row) {
  return row.map((key, value) {
    if (value is Uint8List) {
      return MapEntry(key, List<int>.unmodifiable(value));
    }
    return MapEntry(key, value);
  });
}

String _quoteIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}

const _v10SchemaStatements = <String>[
  '''
    CREATE TABLE characters (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      personality TEXT NOT NULL DEFAULT '',
      scenario TEXT NOT NULL DEFAULT '',
      first_message TEXT NOT NULL DEFAULT '',
      alternate_greetings TEXT NOT NULL DEFAULT '[]',
      example_dialogue TEXT NOT NULL DEFAULT '',
      system_prompt TEXT NOT NULL DEFAULT '',
      post_history_instructions TEXT NOT NULL DEFAULT '',
      creator_notes TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      creator TEXT NOT NULL DEFAULT '',
      character_version TEXT NOT NULL DEFAULT '',
      avatar_path TEXT,
      assets_json TEXT NOT NULL DEFAULT '{}',
      character_book_json TEXT NOT NULL DEFAULT '',
      extensions_json TEXT NOT NULL DEFAULT '{}',
      is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE chats (
      id TEXT NOT NULL PRIMARY KEY,
      character_id TEXT NOT NULL REFERENCES characters (id),
      group_id TEXT,
      title TEXT NOT NULL DEFAULT 'New Chat',
      settings_json TEXT NOT NULL DEFAULT '{}',
      author_note TEXT NOT NULL DEFAULT '',
      author_note_depth INTEGER NOT NULL DEFAULT 4,
      author_note_enabled INTEGER NOT NULL DEFAULT 0
        CHECK (author_note_enabled IN (0, 1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE messages (
      id TEXT NOT NULL PRIMARY KEY,
      chat_id TEXT NOT NULL REFERENCES chats (id),
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      swipes TEXT NOT NULL DEFAULT '[]',
      current_swipe_index INTEGER NOT NULL DEFAULT 0,
      is_edited INTEGER NOT NULL DEFAULT 0 CHECK (is_edited IN (0, 1)),
      is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1)),
      metadata_json TEXT NOT NULL DEFAULT '{}',
      character_id TEXT,
      character_name TEXT,
      attachments_json TEXT NOT NULL DEFAULT '[]'
    )
  ''',
  '''
    CREATE TABLE world_infos (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      is_global INTEGER NOT NULL DEFAULT 0 CHECK (is_global IN (0, 1)),
      character_id TEXT REFERENCES characters (id),
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE world_info_entries (
      id TEXT NOT NULL PRIMARY KEY,
      world_info_id TEXT NOT NULL REFERENCES world_infos (id),
      keys TEXT NOT NULL DEFAULT '[]',
      secondary_keys TEXT NOT NULL DEFAULT '[]',
      content TEXT NOT NULL DEFAULT '',
      comment TEXT NOT NULL DEFAULT '',
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      constant INTEGER NOT NULL DEFAULT 0 CHECK (constant IN (0, 1)),
      selective INTEGER NOT NULL DEFAULT 0 CHECK (selective IN (0, 1)),
      insertion_order INTEGER NOT NULL DEFAULT 0,
      case_sensitive INTEGER NOT NULL DEFAULT 0 CHECK (case_sensitive IN (0, 1)),
      match_whole_words INTEGER NOT NULL DEFAULT 0
        CHECK (match_whole_words IN (0, 1)),
      probability INTEGER NOT NULL DEFAULT 100,
      position INTEGER NOT NULL DEFAULT 1,
      depth INTEGER NOT NULL DEFAULT 4,
      "group" TEXT,
      group_weight INTEGER NOT NULL DEFAULT 100,
      prevent_recursion INTEGER NOT NULL DEFAULT 0
        CHECK (prevent_recursion IN (0, 1)),
      scan_depth INTEGER NOT NULL DEFAULT 1000,
      extensions_json TEXT NOT NULL DEFAULT '{}'
    )
  ''',
  '''
    CREATE TABLE llm_configs (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      provider TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      api_key TEXT,
      model TEXT,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
      is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
      default_settings_json TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE personas (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      avatar_path TEXT,
      is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE groups (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      members_json TEXT NOT NULL DEFAULT '[]',
      settings_json TEXT NOT NULL DEFAULT '{}',
      avatar_path TEXT,
      created_at INTEGER NOT NULL,
      modified_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE bookmarks (
      id TEXT NOT NULL PRIMARY KEY,
      chat_id TEXT NOT NULL REFERENCES chats (id),
      name TEXT NOT NULL,
      description TEXT,
      message_id TEXT NOT NULL,
      message_index INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE tags (
      id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      color TEXT,
      icon TEXT,
      created_at INTEGER NOT NULL
    )
  ''',
  '''
    CREATE TABLE character_tags (
      character_id TEXT NOT NULL REFERENCES characters (id),
      tag_id TEXT NOT NULL REFERENCES tags (id),
      PRIMARY KEY (character_id, tag_id)
    )
  ''',
];

const _v13SchemaStatements = <String>[
  ..._v10SchemaStatements,
  'ALTER TABLE world_info_entries '
      'ADD COLUMN use_group_scoring INTEGER NOT NULL DEFAULT 0 '
      'CHECK (use_group_scoring IN (0, 1))',
  "ALTER TABLE world_info_entries ADD COLUMN automation_id TEXT NOT NULL DEFAULT ''",
  'ALTER TABLE world_info_entries '
      'ADD COLUMN delay_until_recursion INTEGER NOT NULL DEFAULT 0 '
      'CHECK (delay_until_recursion IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN scan_depth TEXT',
  'ALTER TABLE world_infos ADD COLUMN case_sensitive INTEGER '
      'CHECK (case_sensitive IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN match_whole_words INTEGER '
      'CHECK (match_whole_words IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN use_group_scoring INTEGER '
      'CHECK (use_group_scoring IN (0, 1))',
  'ALTER TABLE world_infos ADD COLUMN recursion_depth INTEGER',
  "ALTER TABLE world_infos ADD COLUMN extensions_json TEXT NOT NULL DEFAULT '{}'",
  '''
    CREATE TABLE global_states (
      key TEXT NOT NULL PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
];

const _representativeLegacySeedStatements = <String>[
  '''
    INSERT INTO characters (
      id, name, description, personality, scenario, first_message,
      alternate_greetings, example_dialogue, system_prompt,
      post_history_instructions, creator_notes, tags, creator,
      character_version, avatar_path, assets_json, character_book_json,
      extensions_json, is_favorite, created_at, modified_at
    ) VALUES (
      'character-1', 'Legacy Hero', 'Preserved description', 'Steady',
      'A migration test', 'Hello {{user}}', '["Welcome","Greetings"]',
      '<START>\n{{char}}: Example', 'Stay in character', 'Remember the quest',
      'Imported from v10', '["legacy","favorite"]', 'Fixture Author', '1.0',
      '/tmp/avatar.png', '{"sprites":["smile.png"]}',
      '{"entries":[{"keys":["lore"],"content":"Stored lore"}]}',
      '{"talkativeness":"0.75"}', 1, 1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO chats (
      id, character_id, title, settings_json, author_note, author_note_depth,
      author_note_enabled, created_at, updated_at
    ) VALUES (
      'chat-1', 'character-1', 'Legacy chat',
      '{"startReplyWith":"Once ","nested":{"enabled":true}}',
      'Keep this note', 3, 1, 1704240000, 1704326400
    )
  ''',
  '''
    INSERT INTO messages (
      id, chat_id, role, content, timestamp, swipes, current_swipe_index,
      is_edited, is_hidden, metadata_json, attachments_json
    ) VALUES (
      'message-1', 'chat-1', 'assistant', 'Hello traveler', 1704240100,
      '["Hello traveler","Welcome back"]', 1, 1, 0,
      '{"reasoning":"fixture"}',
      '[{"id":"attachment-1","path":"/tmp/map.png","mimeType":"image/png"}]'
    )
  ''',
  '''
    INSERT INTO world_infos (
      id, name, description, enabled, is_global, character_id,
      created_at, modified_at
    ) VALUES (
      'world-1', 'Legacy lore', 'World description', 1, 0, 'character-1',
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO world_info_entries (
      id, world_info_id, keys, secondary_keys, content, comment, enabled,
      constant, selective, insertion_order, case_sensitive, match_whole_words,
      probability, position, depth, "group", group_weight, prevent_recursion,
      scan_depth, extensions_json
    ) VALUES (
      'entry-1', 'world-1', '["castle","keep"]', '["north"]',
      'The castle is guarded.', 'Legacy entry', 1, 0, 1, 7, 1, 0,
      80, 1, 4, 'places', 75, 0, 512, '{"displayIndex":3}'
    )
  ''',
  '''
    INSERT INTO llm_configs (
      id, name, provider, endpoint, api_key, model, enabled, is_default,
      default_settings_json, created_at, modified_at
    ) VALUES (
      'llm-1', 'Fixture config', 'openai', 'https://example.invalid/v1',
      NULL, 'fixture-model', 1, 1,
      '{"temperature":0.7,"stop":["END"]}', 1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO personas (
      id, name, description, is_default, created_at, updated_at
    ) VALUES (
      'persona-1', 'Legacy User', 'Persona description', 1,
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO groups (
      id, name, description, members_json, settings_json,
      created_at, modified_at
    ) VALUES (
      'group-1', 'Fixture party', 'Group description',
      '[{"characterId":"character-1","isMuted":false}]',
      '{"activationMode":"manual","generationMode":"swap"}',
      1704067200, 1704153600
    )
  ''',
  '''
    INSERT INTO bookmarks (
      id, chat_id, name, description, message_id, message_index, created_at
    ) VALUES (
      'bookmark-1', 'chat-1', 'Checkpoint', 'Before migration',
      'message-1', 0, 1704240200
    )
  ''',
  '''
    INSERT INTO tags (id, name, color, icon, created_at)
    VALUES ('tag-1', 'Legacy', '#336699', 'history', 1704067200)
  ''',
  '''
    INSERT INTO character_tags (character_id, tag_id)
    VALUES ('character-1', 'tag-1')
  ''',
];

const _v13SeedStatements = <String>[
  '''
    UPDATE world_infos SET
      scan_depth = '321',
      case_sensitive = 1,
      match_whole_words = 0,
      use_group_scoring = 1,
      recursion_depth = 2,
      extensions_json = '{"strategy":"v13"}'
    WHERE id = 'world-1'
  ''',
  '''
    UPDATE world_info_entries SET
      use_group_scoring = 1,
      automation_id = 'automation-1',
      delay_until_recursion = 1
    WHERE id = 'entry-1'
  ''',
  '''
    INSERT INTO global_states (key, value, updated_at)
    VALUES ('active_config', '{"provider":"llm-1"}', 1704326400)
  ''',
];

const _currentOnlySeedStatements = <String>[
  ..._v13SeedStatements,
  '''
    UPDATE personas SET
      connections_json = '[{"characterId":"character-1","lockType":"character"}]',
      description_settings_json = '{"position":"atDepth","depth":3,"role":"user"}',
      lorebook_id = 'world-1',
      system_prompt_override = 'Persona system prompt',
      post_history_instructions = 'Persona post-history prompt',
      tags_json = '["fixture","migration"]',
      creator_notes = 'Private fixture note',
      is_favorite = 1
    WHERE id = 'persona-1'
  ''',
];
