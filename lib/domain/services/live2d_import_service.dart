import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/domain/services/live2d_service.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class Live2DImportException implements Exception {
  final String message;

  const Live2DImportException(this.message);

  @override
  String toString() => message;
}

class Live2DImportedPackage {
  final String directoryPath;
  final List<Live2DModelDefinition> models;

  Live2DImportedPackage({
    required this.directoryPath,
    required List<Live2DModelDefinition> models,
  }) : models = List.unmodifiable(models);
}

class Live2DPackageDeletionResult {
  final Live2DImportedPackage package;
  final bool cleanupPending;

  const Live2DPackageDeletionResult({
    required this.package,
    required this.cleanupPending,
  });
}

/// Imports user-owned Live2D ZIP packages into NativeTavern's data directory.
class Live2DImportService {
  static const maxArchiveBytes = 128 * 1024 * 1024;
  static const maxExtractedBytes = 512 * 1024 * 1024;
  static const maxSingleFileBytes = 128 * 1024 * 1024;
  static const maxEntries = 5000;
  static const orphanStagingGracePeriod = Duration(hours: 1);
  static const _metadataFileName = '.nativetavern-live2d.json';
  static const _importMarkerFileName = '.nativetavern-importing';
  static const _uuid = Uuid();

  static const _allowedExtensions = {
    '.json',
    '.moc3',
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.bmp',
    '.wav',
    '.mp3',
    '.ogg',
    '.m4a',
    '.txt',
    '.md',
    '.license',
  };

  final String dataPath;
  final Live2DService modelService;

  const Live2DImportService({
    required this.dataPath,
    required this.modelService,
  });

  Directory get _modelsRoot => Directory(p.join(dataPath, 'live2d_models'));

  Future<List<Live2DModelDefinition>> listImportedModels() async {
    await cleanupOrphanDirectories();
    final root = _modelsRoot;
    if (!root.existsSync()) return const [];

    final models = <Live2DModelDefinition>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      models.addAll(await _readPackageModels(entity));
    }
    models.sort((a, b) => a.displayName.compareTo(b.displayName));
    return models;
  }

  /// Removes staging and quarantined directories left by interrupted imports
  /// or deletions. Normal package directories are never touched here.
  Future<void> cleanupOrphanDirectories() async {
    final root = _modelsRoot;
    if (!root.existsSync()) return;
    final staleBefore = DateTime.now().subtract(orphanStagingGracePeriod);
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith('.import-') && !name.startsWith('.deleting-')) {
        continue;
      }
      if (name.startsWith('.import-')) {
        final marker = File(p.join(entity.path, _importMarkerFileName));
        final modified = marker.existsSync()
            ? marker.lastModifiedSync()
            : entity.statSync().modified;
        if (modified.isAfter(staleBefore)) continue;
      }
      try {
        await entity.delete(recursive: entity is Directory);
      } catch (_) {
        // A later library refresh retries cleanup without hiding valid models.
      }
    }
  }

  /// Resolves the package containing [definition] and verifies that it is a
  /// real, metadata-backed child of the managed Live2D directory.
  Future<Live2DImportedPackage> inspectImportedPackage(
    Live2DModelDefinition definition,
  ) async {
    if (definition.source != Live2DModelSource.appData) {
      throw const Live2DImportException(
        'Only imported Live2D models can be deleted.',
      );
    }
    final relativeDirectory = definition.modelDirectory.replaceAll('\\', '/');
    if (_isAbsolutePath(relativeDirectory)) {
      throw const Live2DImportException(
        'The imported model path is outside the managed Live2D directory.',
      );
    }

    final root = _modelsRoot;
    if (!root.existsSync()) {
      throw const Live2DImportException(
        'The imported model package is missing.',
      );
    }
    final rootPath = p.normalize(p.absolute(root.path));
    final modelDirectory = p.normalize(
      p.absolute(p.join(dataPath, relativeDirectory)),
    );
    if (!p.isWithin(rootPath, modelDirectory)) {
      throw const Live2DImportException(
        'The imported model path is outside the managed Live2D directory.',
      );
    }

    final relativeToRoot = p.relative(modelDirectory, from: rootPath);
    final segments = p.split(relativeToRoot);
    if (segments.isEmpty ||
        segments.first == '.' ||
        segments.first == '..' ||
        segments.first.startsWith('.')) {
      throw const Live2DImportException('Invalid imported model package path.');
    }
    final packageDirectory = Directory(p.join(rootPath, segments.first));
    final entityType = FileSystemEntity.typeSync(
      packageDirectory.path,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.directory) {
      throw const Live2DImportException(
        'The imported model package is missing.',
      );
    }

    final resolvedRoot = p.normalize(await root.resolveSymbolicLinks());
    final resolvedPackage =
        p.normalize(await packageDirectory.resolveSymbolicLinks());
    if (!p.isWithin(resolvedRoot, resolvedPackage)) {
      throw const Live2DImportException(
        'The imported model package resolves outside the managed directory.',
      );
    }

    final models = await _readPackageModels(packageDirectory);
    final containsTarget = models.any((model) {
      return model.id == definition.id &&
          model.modelFileName == definition.modelFileName &&
          p.equals(
            p.normalize(model.modelDirectory),
            p.normalize(definition.modelDirectory),
          );
    });
    if (!containsTarget) {
      throw const Live2DImportException(
        'The imported model does not match its package metadata.',
      );
    }
    return Live2DImportedPackage(
      directoryPath: packageDirectory.path,
      models: models,
    );
  }

  /// Atomically hides a validated package before deleting its files. Once the
  /// rename succeeds, a failed recursive cleanup is safe to retry later.
  Future<Live2DPackageDeletionResult> deleteImportedPackage(
    Live2DModelDefinition definition,
  ) async {
    final package = await inspectImportedPackage(definition);
    final packageDirectory = Directory(package.directoryPath);
    final quarantine = Directory(
      p.join(
        _modelsRoot.path,
        '.deleting-${p.basename(package.directoryPath)}-${_uuid.v4()}',
      ),
    );
    try {
      await packageDirectory.rename(quarantine.path);
    } on FileSystemException catch (error) {
      throw Live2DImportException(
        'The imported model package could not be quarantined: ${error.message}',
      );
    }

    var cleanupPending = false;
    try {
      await quarantine.delete(recursive: true);
    } catch (_) {
      cleanupPending = true;
    }
    return Live2DPackageDeletionResult(
      package: package,
      cleanupPending: cleanupPending,
    );
  }

  Future<List<Live2DModelDefinition>> importZip(File zipFile) async {
    if (!zipFile.existsSync()) {
      throw const Live2DImportException(
          'The selected ZIP file does not exist.');
    }
    if (p.extension(zipFile.path).toLowerCase() != '.zip') {
      throw const Live2DImportException('Select a Live2D ZIP archive.');
    }
    final archiveSize = zipFile.lengthSync();
    if (archiveSize <= 0 || archiveSize > maxArchiveBytes) {
      throw const Live2DImportException(
        'The ZIP archive is empty or exceeds the 128 MB limit.',
      );
    }

    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    if (archive.isEmpty || archive.length > maxEntries) {
      throw const Live2DImportException(
        'The ZIP archive is empty or contains too many entries.',
      );
    }

    final validatedEntries = <(ArchiveFile, String)>[];
    final outputNames = <String>{};
    var extractedBytes = 0;
    for (final entry in archive) {
      final relativePath = _validateArchivePath(entry.name);
      if (relativePath == null || !entry.isFile) continue;
      if (entry.isSymbolicLink) {
        throw const Live2DImportException(
          'Symbolic links are not allowed in Live2D archives.',
        );
      }
      if (!_shouldExtract(relativePath)) continue;
      if (entry.size < 0 || entry.size > maxSingleFileBytes) {
        throw Live2DImportException(
          'Archive entry is too large: ${entry.name}',
        );
      }
      extractedBytes += entry.size;
      if (extractedBytes > maxExtractedBytes) {
        throw const Live2DImportException(
          'The extracted Live2D package exceeds the 512 MB limit.',
        );
      }
      if (!outputNames.add(relativePath.toLowerCase())) {
        throw Live2DImportException(
          'The archive contains duplicate paths: $relativePath',
        );
      }
      validatedEntries.add((entry, relativePath));
    }

    final importId = _uuid.v4();
    final root = _modelsRoot;
    await root.create(recursive: true);
    final staging = Directory(p.join(root.path, '.import-$importId'));
    final packageName =
        '${_safeName(p.basenameWithoutExtension(zipFile.path))}-${importId.substring(0, 8)}';
    final destination = Directory(p.join(root.path, packageName));

    try {
      await staging.create(recursive: true);
      final importMarker = File(p.join(staging.path, _importMarkerFileName));
      await importMarker.writeAsString(
        DateTime.now().toUtc().toIso8601String(),
        flush: true,
      );
      for (final (entry, relativePath) in validatedEntries) {
        final content = entry.content;
        if (content is! List<int> || content.length > maxSingleFileBytes) {
          throw Live2DImportException(
            'Invalid or oversized archive entry: ${entry.name}',
          );
        }
        final output = File(p.join(staging.path, relativePath));
        await output.parent.create(recursive: true);
        await output.writeAsBytes(content, flush: true);
      }

      final modelFiles = <File>[];
      await for (final entity in staging.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File &&
            entity.path.toLowerCase().endsWith('.model3.json')) {
          modelFiles.add(entity);
        }
      }
      if (modelFiles.isEmpty) {
        throw const Live2DImportException(
          'No *.model3.json file was found in the ZIP archive.',
        );
      }

      final metadataModels = <Map<String, dynamic>>[];
      for (var index = 0; index < modelFiles.length; index++) {
        final modelFile = modelFiles[index];
        final modelDirectory = modelFile.parent.path;
        final manifest = modelService.parseManifest(
          await modelFile.readAsString(),
        );
        if (manifest.version < 3 ||
            manifest.mocFile.isEmpty ||
            manifest.textures.isEmpty) {
          throw Live2DImportException(
            'Invalid Cubism 3+ model definition: ${p.basename(modelFile.path)}',
          );
        }
        final missing = <String>[];
        for (final reference in manifest.referencedFiles) {
          final normalizedReference = reference.replaceAll('\\', '/');
          final isAbsolute = p.isAbsolute(normalizedReference) ||
              normalizedReference.startsWith('/') ||
              RegExp(r'^[a-zA-Z]:/').hasMatch(normalizedReference);
          final resolved =
              p.normalize(p.join(modelDirectory, normalizedReference));
          if (isAbsolute ||
              !p.isWithin(staging.path, resolved) ||
              !File(resolved).existsSync()) {
            missing.add(reference);
          }
        }
        if (missing.isNotEmpty) {
          throw Live2DImportException(
            '${p.basename(modelFile.path)} references missing or unsafe file: '
            '${missing.first}',
          );
        }

        final relativeDirectory = p.relative(
          modelDirectory,
          from: staging.path,
        );
        final baseName = p.basename(modelFile.path).replaceFirst(
              RegExp(r'\.model3\.json$', caseSensitive: false),
              '',
            );
        metadataModels.add({
          'id': 'imported:$importId:$index',
          'displayName': _displayName(baseName),
          'relativeDirectory':
              relativeDirectory == '.' ? '' : relativeDirectory,
          'modelFileName': p.basename(modelFile.path),
        });
      }

      final metadata = {
        'version': 1,
        'importedAt': DateTime.now().toUtc().toIso8601String(),
        'sourceArchive': p.basename(zipFile.path),
        'models': metadataModels,
      };
      await File(p.join(staging.path, _metadataFileName)).writeAsString(
        jsonEncode(metadata),
        flush: true,
      );
      await importMarker.delete();
      await staging.rename(destination.path);
      return _definitionsFromMetadata(destination, metadataModels);
    } catch (_) {
      if (staging.existsSync()) await staging.delete(recursive: true);
      if (destination.existsSync()) await destination.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<Live2DModelDefinition>> _readPackageModels(
    Directory package,
  ) async {
    final metadataFile = File(p.join(package.path, _metadataFileName));
    if (!metadataFile.existsSync()) return const [];
    try {
      final metadata = jsonDecode(await metadataFile.readAsString());
      if (metadata is! Map<String, dynamic>) return const [];
      final models = (metadata['models'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      return _definitionsFromMetadata(package, models).where((definition) {
        final absoluteDirectory = p.join(dataPath, definition.modelDirectory);
        return File(
          p.join(absoluteDirectory, definition.modelFileName),
        ).existsSync();
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  List<Live2DModelDefinition> _definitionsFromMetadata(
    Directory package,
    List<Map<String, dynamic>> models,
  ) {
    final root = _modelsRoot.path;
    return models.map((model) {
      final relativeDirectory = model['relativeDirectory'] as String? ?? '';
      final modelFileName = model['modelFileName'] as String? ?? '';
      final absoluteDirectory = p.normalize(
        p.join(package.path, relativeDirectory),
      );
      if ((absoluteDirectory != package.path &&
              !p.isWithin(package.path, absoluteDirectory)) ||
          modelFileName.isEmpty ||
          p.basename(modelFileName) != modelFileName ||
          p.isAbsolute(modelFileName)) {
        throw const Live2DImportException('Invalid imported model metadata.');
      }
      return Live2DModelDefinition(
        id: model['id'] as String? ?? '',
        displayName: model['displayName'] as String? ?? 'Imported model',
        modelDirectory: p.relative(absoluteDirectory, from: dataPath),
        modelFileName: modelFileName,
        source: Live2DModelSource.appData,
      );
    }).where((definition) {
      final absolute = p.normalize(p.join(dataPath, definition.modelDirectory));
      return p.isWithin(root, absolute) || absolute == root;
    }).toList();
  }

  String? _validateArchivePath(String rawPath) {
    final normalized = rawPath.replaceAll('\\', '/').trim();
    if (normalized.isEmpty || normalized.endsWith('/')) return null;
    if (normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:/').hasMatch(normalized) ||
        normalized.contains('\u0000')) {
      throw Live2DImportException('Unsafe archive path: $rawPath');
    }
    final segments = normalized.split('/');
    if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw Live2DImportException('Unsafe archive path: $rawPath');
    }
    if (segments.first == '__MACOSX' || p.basename(normalized) == '.DS_Store') {
      return null;
    }
    return p.joinAll(segments);
  }

  bool _isAbsolutePath(String value) {
    return p.isAbsolute(value) ||
        value.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:/').hasMatch(value);
  }

  bool _shouldExtract(String path) {
    final extension = p.extension(path).toLowerCase();
    if (_allowedExtensions.contains(extension)) return true;
    final name = p.basename(path).toLowerCase();
    return name == 'license' || name == 'notice' || name == 'readme';
  }

  String _safeName(String value) {
    final safe = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return safe.isEmpty ? 'live2d-model' : safe;
  }

  String _displayName(String value) {
    return value.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }
}

final live2DImportServiceProvider = Provider<Live2DImportService>((ref) {
  return Live2DImportService(
    dataPath: ref.watch(dataPathProvider),
    modelService: ref.watch(live2DServiceProvider),
  );
});
