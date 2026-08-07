/// Where a Live2D model is loaded from.
enum Live2DModelSource {
  asset,
  appData,
  fileSystem;

  static Live2DModelSource fromJson(String? value) {
    return Live2DModelSource.values.firstWhere(
      (source) => source.name == value,
      orElse: () => asset,
    );
  }
}

/// A motion's stable address inside a Cubism model definition.
class Live2DMotionRef {
  final String group;
  final int index;
  final String file;
  final String name;

  const Live2DMotionRef({
    required this.group,
    required this.index,
    required this.file,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
        'group': group,
        'index': index,
        'file': file,
        'name': name,
      };

  factory Live2DMotionRef.fromJson(Map<String, dynamic> json) {
    return Live2DMotionRef(
      group: json['group'] as String? ?? '',
      index: (json['index'] as num?)?.toInt() ?? 0,
      file: json['file'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}

/// A model available to NativeTavern before it is assigned to a character.
class Live2DModelDefinition {
  final String id;
  final String displayName;
  final String modelDirectory;
  final String modelFileName;
  final Live2DModelSource source;

  const Live2DModelDefinition({
    required this.id,
    required this.displayName,
    required this.modelDirectory,
    required this.modelFileName,
    this.source = Live2DModelSource.asset,
  });
}

/// Parsed data from a Cubism `*.model3.json` file.
class Live2DModelManifest {
  final int version;
  final String mocFile;
  final List<String> textures;
  final String? physicsFile;
  final String? poseFile;
  final List<String> expressions;
  final List<Live2DMotionRef> motions;
  final List<String> lipSyncParameters;

  const Live2DModelManifest({
    required this.version,
    required this.mocFile,
    required this.textures,
    this.physicsFile,
    this.poseFile,
    this.expressions = const [],
    this.motions = const [],
    this.lipSyncParameters = const [],
  });

  Iterable<String> get referencedFiles sync* {
    if (mocFile.isNotEmpty) yield mocFile;
    yield* textures;
    if (physicsFile case final value?) yield value;
    if (poseFile case final value?) yield value;
    yield* expressions;
    for (final motion in motions) {
      if (motion.file.isNotEmpty) yield motion.file;
    }
  }

  Live2DMotionRef? findMotion(Iterable<String> preferredNames) {
    final normalized = preferredNames
        .map((name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .toList();
    for (final preferred in normalized) {
      for (final motion in motions) {
        final nameCandidate =
            motion.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final groupCandidate =
            motion.group.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (nameCandidate == preferred || groupCandidate == preferred) {
          return motion;
        }
      }
    }
    return null;
  }
}

/// Per-character Live2D assignment and stage presentation.
class Live2DConfig {
  final bool enabled;
  final String modelId;
  final String displayName;
  final String modelDirectory;
  final String modelFileName;
  final Live2DModelSource source;
  final double scale;
  final double offsetX;
  final double offsetY;
  final double opacity;
  final double motionSpeed;
  final Live2DMotionRef? idleMotion;
  final Live2DMotionRef? tapMotion;
  final Live2DMotionRef? speakingMotion;
  final Live2DMotionRef? responseMotion;
  final String lipSyncParameter;

  const Live2DConfig({
    this.enabled = true,
    required this.modelId,
    required this.displayName,
    required this.modelDirectory,
    required this.modelFileName,
    this.source = Live2DModelSource.asset,
    this.scale = 1,
    this.offsetX = 0,
    this.offsetY = 0,
    this.opacity = 1,
    this.motionSpeed = 1,
    this.idleMotion,
    this.tapMotion,
    this.speakingMotion,
    this.responseMotion,
    this.lipSyncParameter = 'ParamMouthOpenY',
  });

  factory Live2DConfig.fromDefinition(
    Live2DModelDefinition definition,
    Live2DModelManifest manifest,
  ) {
    return Live2DConfig(
      modelId: definition.id,
      displayName: definition.displayName,
      modelDirectory: definition.modelDirectory,
      modelFileName: definition.modelFileName,
      source: definition.source,
      idleMotion: manifest.findMotion(const ['idle']),
      tapMotion: manifest.findMotion(
        const [
          'touch_body',
          'touch_special',
          'touch_head',
          'tap_body',
          'tap',
          'flick_body',
          'flick',
        ],
      ),
      speakingMotion: manifest.findMotion(
        const ['main_1', 'main_2', 'main_3', 'effect'],
      ),
      responseMotion: manifest.findMotion(
        const ['complete', 'mission_complete'],
      ),
      lipSyncParameter:
          manifest.lipSyncParameters.firstOrNull ?? 'ParamMouthOpenY',
    );
  }

  Live2DConfig copyWith({
    bool? enabled,
    String? modelId,
    String? displayName,
    String? modelDirectory,
    String? modelFileName,
    Live2DModelSource? source,
    double? scale,
    double? offsetX,
    double? offsetY,
    double? opacity,
    double? motionSpeed,
    Live2DMotionRef? idleMotion,
    Live2DMotionRef? tapMotion,
    Live2DMotionRef? speakingMotion,
    Live2DMotionRef? responseMotion,
    String? lipSyncParameter,
  }) {
    return Live2DConfig(
      enabled: enabled ?? this.enabled,
      modelId: modelId ?? this.modelId,
      displayName: displayName ?? this.displayName,
      modelDirectory: modelDirectory ?? this.modelDirectory,
      modelFileName: modelFileName ?? this.modelFileName,
      source: source ?? this.source,
      scale: scale ?? this.scale,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      opacity: opacity ?? this.opacity,
      motionSpeed: motionSpeed ?? this.motionSpeed,
      idleMotion: idleMotion ?? this.idleMotion,
      tapMotion: tapMotion ?? this.tapMotion,
      speakingMotion: speakingMotion ?? this.speakingMotion,
      responseMotion: responseMotion ?? this.responseMotion,
      lipSyncParameter: lipSyncParameter ?? this.lipSyncParameter,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'modelId': modelId,
        'displayName': displayName,
        'modelDirectory': modelDirectory,
        'modelFileName': modelFileName,
        'source': source.name,
        'scale': scale,
        'offsetX': offsetX,
        'offsetY': offsetY,
        'opacity': opacity,
        'motionSpeed': motionSpeed,
        'idleMotion': idleMotion?.toJson(),
        'tapMotion': tapMotion?.toJson(),
        'speakingMotion': speakingMotion?.toJson(),
        'responseMotion': responseMotion?.toJson(),
        'lipSyncParameter': lipSyncParameter,
      };

  factory Live2DConfig.fromJson(Map<String, dynamic> json) {
    Live2DMotionRef? parseMotion(String key) {
      final value = json[key];
      return value is Map<String, dynamic>
          ? Live2DMotionRef.fromJson(value)
          : null;
    }

    return Live2DConfig(
      enabled: json['enabled'] as bool? ?? true,
      modelId: json['modelId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      modelDirectory: json['modelDirectory'] as String? ?? '',
      modelFileName: json['modelFileName'] as String? ?? '',
      source: Live2DModelSource.fromJson(json['source'] as String?),
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1,
      motionSpeed: (json['motionSpeed'] as num?)?.toDouble() ?? 1,
      idleMotion: parseMotion('idleMotion'),
      tapMotion: parseMotion('tapMotion'),
      speakingMotion: parseMotion('speakingMotion'),
      responseMotion: parseMotion('responseMotion'),
      lipSyncParameter:
          json['lipSyncParameter'] as String? ?? 'ParamMouthOpenY',
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
