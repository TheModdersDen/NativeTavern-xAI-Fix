import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/database_backup_service.dart';

import 'support/database_migration_harness.dart';

void main() {
  late MigrationTestHarness harness;

  setUp(() {
    harness = MigrationTestHarness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('fresh databases create the complete current schema', () async {
    final database = harness.createCurrentDatabase();

    expect(await readSchemaVersion(database), 15);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(
      await readTableNames(database),
      containsAll(currentSnapshotTables.map((table) => table.name)),
    );
  });

  test('v10 fixture migrates through v11-v15 without losing logical data',
      () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v10);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV10PreservedSnapshotTables,
    );
    final database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), 15);
    final after = await captureDatabaseSnapshot(
      database,
      legacyV10PreservedSnapshotTables,
    );

    expect(after.tables, before.tables);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(await readTableNames(database), contains('global_states'));

    final worldInfo = await database.customSelect('''
      SELECT scan_depth, case_sensitive, match_whole_words,
             use_group_scoring, recursion_depth, extensions_json
      FROM world_infos WHERE id = 'world-1'
    ''').getSingle();
    expect(
      worldInfo.data,
      {
        'scan_depth': null,
        'case_sensitive': null,
        'match_whole_words': null,
        'use_group_scoring': null,
        'recursion_depth': null,
        'extensions_json': '{}',
      },
    );

    final persona = await database.customSelect('''
      SELECT connections_json, description_settings_json, lorebook_id,
             system_prompt_override, post_history_instructions, tags_json,
             creator_notes, is_favorite
      FROM personas WHERE id = 'persona-1'
    ''').getSingle();
    expect(
      persona.data,
      {
        'connections_json': '[]',
        'description_settings_json': '{}',
        'lorebook_id': null,
        'system_prompt_override': null,
        'post_history_instructions': null,
        'tags_json': '[]',
        'creator_notes': '',
        'is_favorite': 0,
      },
    );
  });

  test('v13 fixture preserves extended world-info and global-state data',
      () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v13);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV13PreservedSnapshotTables,
    );
    final database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), 15);
    final after = await captureDatabaseSnapshot(
      database,
      legacyV13PreservedSnapshotTables,
    );

    expect(after.tables, before.tables);
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
  });

  test('v14 fixture gains all domain tables and can be reopened', () async {
    final file = harness.createFixture(LegacyDatabaseFixtures.v14);
    final before = captureRawDatabaseSnapshot(
      file,
      legacyV13PreservedSnapshotTables,
    );
    var database = harness.openWithProductionMigrations(file);

    expect(await readSchemaVersion(database), 15);
    expect(
      (await captureDatabaseSnapshot(
        database,
        legacyV13PreservedSnapshotTables,
      ))
          .tables,
      before.tables,
    );
    expect(await runIntegrityCheck(database), 'ok');
    expect(await findForeignKeyViolations(database), isEmpty);
    expect(
      await readTableNames(database),
      containsAll(currentSnapshotTables.map((table) => table.name)),
    );

    await harness.close(database);
    database = harness.openWithProductionMigrations(file);
    expect(await readSchemaVersion(database), 15);
    expect(await runIntegrityCheck(database), 'ok');
  });

  test('failed v15 migration rolls back every new table', () async {
    final file = harness.createFixture(
      LegacyDatabaseFixtures.interruptedV14,
      name: 'interrupted_v14',
    );
    final database = harness.openWithProductionMigrations(file);

    await expectLater(
        database.customSelect('SELECT 1').get(), throwsA(anything));
    await harness.close(database);

    expect(readRawSchemaVersion(file), 14);
    expect(readRawTableNames(file), isNot(contains('long_term_memories')));
    expect(readRawTableNames(file), contains('rpg_scenarios'));
  });

  test('failed migration rolls back schema changes and version advancement',
      () async {
    final file = harness.createFixture(
      LegacyDatabaseFixtures.interruptedV10,
      name: 'interrupted_v10',
    );
    final database = harness.openWithProductionMigrations(file);

    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(anything),
    );
    await harness.close(database);

    expect(readRawSchemaVersion(file), 10);
    final columns = readRawTableColumns(file, 'world_info_entries');
    expect(columns, contains('automation_id'));
    expect(columns, isNot(contains('use_group_scoring')));
    expect(columns, isNot(contains('delay_until_recursion')));
  });

  test('logical backup and restore produce equivalent current data', () async {
    final source = harness.createCurrentDatabase(name: 'backup_source');
    await seedCurrentRepresentativeData(source);
    final expected = await captureDatabaseSnapshot(
      source,
      currentSnapshotTables,
    );
    final backup = await DatabaseBackupService(source).exportAllData();
    await harness.close(source);

    final restored = harness.createCurrentDatabase(name: 'backup_restored');
    expect(await readSchemaVersion(restored), 15);
    final result = await DatabaseBackupService(restored).importData(
      data: backup,
      mode: ImportMode.addNewOnly,
    );
    final actual = await captureDatabaseSnapshot(
      restored,
      currentSnapshotTables,
    );

    expect(result.charactersAdded, 1);
    expect(result.chatsAdded, 1);
    expect(result.messagesAdded, 1);
    expect(result.personasAdded, 1);
    expect(actual.tables, expected.tables);
    expect(await runIntegrityCheck(restored), 'ok');
    expect(await findForeignKeyViolations(restored), isEmpty);
  });
}
