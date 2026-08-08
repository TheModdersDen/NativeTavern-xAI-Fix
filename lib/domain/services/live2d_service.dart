import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:path/path.dart' as p;

/// Discovers and validates Cubism model metadata without loading native code.
class Live2DService {
  final String? dataPath;

  const Live2DService({this.dataPath});

  static const bundledModels = <Live2DModelDefinition>[
    Live2DModelDefinition(
      id: 'hiyori_free',
      displayName: 'Hiyori Momose (Official Sample)',
      modelDirectory: 'assets/live2d/hiyori_free/',
      modelFileName: 'hiyori_free_t08.model3.json',
    ),
  ];

  Future<Live2DModelManifest> loadManifest(
    Live2DModelDefinition definition,
  ) async {
    final modelDirectory = _resolveModelDirectory(definition);
    final jsonText = switch (definition.source) {
      Live2DModelSource.asset => await rootBundle.loadString(
          '${definition.modelDirectory}${definition.modelFileName}',
        ),
      Live2DModelSource.appData || Live2DModelSource.fileSystem => await File(
          p.join(modelDirectory, definition.modelFileName),
        ).readAsString(),
    };
    return parseManifest(jsonText);
  }

  Live2DModelManifest parseManifest(String jsonText) {
    final root = jsonDecode(jsonText) as Map<String, dynamic>;
    final references =
        root['FileReferences'] as Map<String, dynamic>? ?? const {};
    final motions = <Live2DMotionRef>[];
    final motionGroups =
        references['Motions'] as Map<String, dynamic>? ?? const {};

    for (final entry in motionGroups.entries) {
      final items = entry.value as List<dynamic>? ?? const [];
      for (var index = 0; index < items.length; index++) {
        final item = items[index] as Map<String, dynamic>? ?? const {};
        final file = item['File'] as String? ?? '';
        motions.add(Live2DMotionRef(
          group: entry.key,
          index: index,
          file: file,
          name: _motionName(file, entry.key, index),
        ));
      }
    }

    final expressions = <String>[];
    for (final raw in references['Expressions'] as List<dynamic>? ?? const []) {
      if (raw is Map<String, dynamic> && raw['File'] is String) {
        expressions.add(raw['File'] as String);
      }
    }

    final lipSyncParameters = <String>[];
    for (final raw in root['Groups'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic> || raw['Name'] != 'LipSync') continue;
      for (final id in raw['Ids'] as List<dynamic>? ?? const []) {
        if (id is String) lipSyncParameters.add(id);
      }
    }

    final hitAreas = <Live2DHitArea>[];
    for (final raw in root['HitAreas'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['Id'] as String? ?? '';
      final name = raw['Name'] as String? ?? '';
      if (id.isEmpty && name.isEmpty) continue;
      hitAreas.add(Live2DHitArea(id: id, name: name));
    }

    return Live2DModelManifest(
      version: (root['Version'] as num?)?.toInt() ?? 0,
      mocFile: references['Moc'] as String? ?? '',
      textures: (references['Textures'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      physicsFile: references['Physics'] as String?,
      poseFile: references['Pose'] as String?,
      expressions: expressions,
      motions: motions,
      hitAreas: hitAreas,
      lipSyncParameters: lipSyncParameters,
    );
  }

  /// Returns referenced files that cannot be found beside the model JSON.
  Future<List<String>> findMissingFiles(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) async {
    final missing = <String>[];
    final modelDirectory = _resolveModelDirectory(definition);
    for (final file in manifest.referencedFiles) {
      try {
        switch (definition.source) {
          case Live2DModelSource.asset:
            await rootBundle.load('${definition.modelDirectory}$file');
          case Live2DModelSource.appData:
          case Live2DModelSource.fileSystem:
            if (!File(p.join(modelDirectory, file)).existsSync()) {
              missing.add(file);
            }
        }
      } catch (_) {
        missing.add(file);
      }
    }
    return missing;
  }

  String _resolveModelDirectory(Live2DModelDefinition definition) {
    if (definition.source != Live2DModelSource.appData) {
      return definition.modelDirectory;
    }
    final root = dataPath;
    if (root == null || root.isEmpty) {
      throw StateError('A data path is required for imported Live2D models.');
    }
    return p.join(root, definition.modelDirectory);
  }

  String _motionName(String file, String group, int index) {
    if (file.isEmpty) return group.isEmpty ? 'Motion ${index + 1}' : group;
    final baseName = p.basename(file).replaceFirst('.motion3.json', '');
    return baseName.replaceAll('_', ' ');
  }
}

final live2DServiceProvider = Provider<Live2DService>((ref) {
  return Live2DService(dataPath: ref.watch(dataPathProvider));
});
