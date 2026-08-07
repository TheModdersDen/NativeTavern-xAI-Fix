import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;
  late Live2DService modelService;
  late Live2DImportService importService;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('nt_live2d_import');
    modelService = Live2DService(dataPath: tempDirectory.path);
    importService = Live2DImportService(
      dataPath: tempDirectory.path,
      modelService: modelService,
    );
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('imports and rediscovers a valid wrapped Live2D ZIP', () async {
    final zipFile = _writeZip(
      tempDirectory,
      'valid.zip',
      _validModelEntries(),
    );

    final imported = await importService.importZip(zipFile);

    expect(imported, hasLength(1));
    expect(imported.single.source, Live2DModelSource.appData);
    expect(p.isAbsolute(imported.single.modelDirectory), isFalse);
    expect(imported.single.displayName, 'test model');

    final manifest = await modelService.loadManifest(imported.single);
    expect(manifest.motions, hasLength(1));
    expect(await modelService.findMissingFiles(imported.single, manifest),
        isEmpty);

    final rediscovered = await importService.listImportedModels();
    expect(rediscovered, hasLength(1));
    expect(rediscovered.single.id, imported.single.id);
    expect(rediscovered.single.modelFileName, 'test_model.model3.json');
  });

  test('rejects path traversal without writing outside the model library',
      () async {
    final entries = _validModelEntries()
      ..['../escaped.txt'] = utf8.encode('not allowed');
    final zipFile = _writeZip(tempDirectory, 'traversal.zip', entries);

    await expectLater(
      importService.importZip(zipFile),
      throwsA(isA<Live2DImportException>()),
    );

    expect(
        File(p.join(tempDirectory.path, 'escaped.txt')).existsSync(), isFalse);
    expect(await importService.listImportedModels(), isEmpty);
  });

  test('rejects missing model references and removes the staging directory',
      () async {
    final entries = _validModelEntries()
      ..remove('package/textures/texture.png');
    final zipFile = _writeZip(tempDirectory, 'missing.zip', entries);

    await expectLater(
      importService.importZip(zipFile),
      throwsA(
        isA<Live2DImportException>().having(
          (error) => error.message,
          'message',
          contains('references missing'),
        ),
      ),
    );

    final modelRoot = Directory(
      p.join(tempDirectory.path, 'live2d_models'),
    );
    final leftovers = modelRoot.existsSync()
        ? modelRoot.listSync().map((entity) => p.basename(entity.path)).toList()
        : const <String>[];
    expect(leftovers, isEmpty);
  });

  test('rejects absolute paths in model references', () async {
    final entries = _validModelEntries();
    const modelPath = 'package/test_model.model3.json';
    final model =
        jsonDecode(utf8.decode(entries[modelPath]!)) as Map<String, dynamic>;
    final references = model['FileReferences'] as Map<String, dynamic>;
    references['Physics'] = '/tmp/outside.physics3.json';
    entries[modelPath] = utf8.encode(jsonEncode(model));
    final zipFile = _writeZip(tempDirectory, 'absolute-reference.zip', entries);

    await expectLater(
      importService.importZip(zipFile),
      throwsA(
        isA<Live2DImportException>().having(
          (error) => error.message,
          'message',
          contains('references missing or unsafe file'),
        ),
      ),
    );

    expect(await importService.listImportedModels(), isEmpty);
  });

  test('repeated imports stay isolated and stale staging directories are removed',
      () async {
    final zipFile = _writeZip(
      tempDirectory,
      'repeated.zip',
      _validModelEntries(),
    );
    final staleImport = Directory(
      p.join(tempDirectory.path, 'live2d_models', '.import-stale'),
    )..createSync(recursive: true);
    final staleMarker = File(
      p.join(staleImport.path, '.nativetavern-importing'),
    )..writeAsStringSync('stale');
    staleMarker.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 2)),
    );
    final staleDeletion = Directory(
      p.join(tempDirectory.path, 'live2d_models', '.deleting-stale'),
    )..createSync(recursive: true);
    final activeImport = Directory(
      p.join(tempDirectory.path, 'live2d_models', '.import-active'),
    )..createSync(recursive: true);
    File(
      p.join(activeImport.path, '.nativetavern-importing'),
    ).writeAsStringSync('active');

    final first = await importService.importZip(zipFile);
    final second = await importService.importZip(zipFile);
    final models = await importService.listImportedModels();

    expect(models, hasLength(2));
    expect(first.single.id, isNot(second.single.id));
    expect(models.map((model) => model.id).toSet(), hasLength(2));
    expect(staleImport.existsSync(), isFalse);
    expect(staleDeletion.existsSync(), isFalse);
    expect(activeImport.existsSync(), isTrue);
  });

  test('deletion rejects bundled and out-of-root model definitions', () async {
    await expectLater(
      importService.deleteImportedPackage(Live2DService.bundledModels.single),
      throwsA(isA<Live2DImportException>()),
    );
    await expectLater(
      importService.deleteImportedPackage(
        const Live2DModelDefinition(
          id: 'outside',
          displayName: 'Outside',
          modelDirectory: '../outside',
          modelFileName: 'outside.model3.json',
          source: Live2DModelSource.appData,
        ),
      ),
      throwsA(isA<Live2DImportException>()),
    );
  });
}

Map<String, List<int>> _validModelEntries() {
  final model = {
    'Version': 3,
    'FileReferences': {
      'Moc': 'test_model.moc3',
      'Textures': ['textures/texture.png'],
      'Physics': 'test_model.physics3.json',
      'Motions': {
        '': [
          {'File': 'motions/idle.motion3.json'},
        ],
      },
    },
    'Groups': [
      {
        'Target': 'Parameter',
        'Name': 'LipSync',
        'Ids': ['ParamMouthOpenY'],
      },
    ],
  };
  return {
    'package/test_model.model3.json': utf8.encode(jsonEncode(model)),
    'package/test_model.moc3': [0x4d, 0x4f, 0x43, 0x33],
    'package/textures/texture.png': [0x89, 0x50, 0x4e, 0x47],
    'package/test_model.physics3.json': utf8.encode('{}'),
    'package/motions/idle.motion3.json': utf8.encode('{}'),
  };
}

File _writeZip(
  Directory directory,
  String name,
  Map<String, List<int>> entries,
) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  final encoded = ZipEncoder().encode(archive);
  return File(p.join(directory.path, name))..writeAsBytesSync(encoded!);
}
