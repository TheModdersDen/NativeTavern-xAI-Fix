import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/live2d.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/services/live2d_import_service.dart';
import 'package:path/path.dart' as p;

class Live2DDeletionException implements Exception {
  final String message;

  const Live2DDeletionException(this.message);

  @override
  String toString() => message;
}

class Live2DDeletionPlan {
  final Live2DModelDefinition target;
  final List<Live2DModelDefinition> packageModels;
  final List<Character> affectedCharacters;

  Live2DDeletionPlan({
    required this.target,
    required List<Live2DModelDefinition> packageModels,
    required List<Character> affectedCharacters,
  })  : packageModels = List.unmodifiable(packageModels),
        affectedCharacters = List.unmodifiable(affectedCharacters);
}

class Live2DDeletionResult {
  final Live2DDeletionPlan plan;
  final bool cleanupPending;

  const Live2DDeletionResult({
    required this.plan,
    required this.cleanupPending,
  });
}

class Live2DModelLifecycleService {
  final CharacterRepository characterRepository;
  final Live2DImportService importService;

  const Live2DModelLifecycleService({
    required this.characterRepository,
    required this.importService,
  });

  Future<Live2DDeletionPlan> planDeletion(
    Live2DModelDefinition definition,
  ) async {
    final package = await importService.inspectImportedPackage(definition);
    final characters = await characterRepository.getAllCharacters();
    final affected = characters
        .where((character) => _referencesAny(character, package.models))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Live2DDeletionPlan(
      target: definition,
      packageModels: package.models,
      affectedCharacters: affected,
    );
  }

  Future<Live2DDeletionResult> deleteImportedModel(
    Live2DModelDefinition definition, {
    Set<String>? confirmedCharacterIds,
  }) async {
    final plan = await planDeletion(definition);
    if (confirmedCharacterIds != null) {
      final currentIds = plan.affectedCharacters.map((c) => c.id).toSet();
      if (!_sameSet(currentIds, confirmedCharacterIds)) {
        throw const Live2DDeletionException(
          'Model references changed. Review the affected characters again.',
        );
      }
    }

    final changed = <Character>[];
    try {
      for (final character in plan.affectedCharacters) {
        await characterRepository.updateCharacter(_withoutLive2D(character));
        changed.add(character);
      }
    } catch (error) {
      await _restoreCharacters(changed);
      throw Live2DDeletionException(
        'Character references could not be updated: $error',
      );
    }

    try {
      final deletion = await importService.deleteImportedPackage(definition);
      return Live2DDeletionResult(
        plan: plan,
        cleanupPending: deletion.cleanupPending,
      );
    } catch (error) {
      await _restoreCharacters(changed);
      throw Live2DDeletionException(
        'The model package could not be deleted: $error',
      );
    }
  }

  bool _referencesAny(
    Character character,
    List<Live2DModelDefinition> definitions,
  ) {
    final config = character.assets?.live2d;
    if (config == null || config.source != Live2DModelSource.appData) {
      return false;
    }
    return definitions.any((definition) {
      return config.modelId == definition.id ||
          (config.modelFileName == definition.modelFileName &&
              p.equals(
                p.normalize(config.modelDirectory),
                p.normalize(definition.modelDirectory),
              ));
    });
  }

  Character _withoutLive2D(Character character) {
    final assets = character.assets;
    if (assets == null) return character;
    final updatedAssets = assets.copyWith(clearLive2D: true);
    return character.copyWith(
      assets: updatedAssets.hasAssets ? updatedAssets : null,
      clearAssets: !updatedAssets.hasAssets,
      modifiedAt: DateTime.now(),
    );
  }

  Future<void> _restoreCharacters(List<Character> originals) async {
    Object? firstError;
    for (final character in originals.reversed) {
      try {
        await characterRepository.updateCharacter(character);
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw Live2DDeletionException(
        'Deletion failed and character references could not be restored: '
        '$firstError',
      );
    }
  }

  bool _sameSet(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }
}

final live2DModelLifecycleServiceProvider =
    Provider<Live2DModelLifecycleService>((ref) {
  return Live2DModelLifecycleService(
    characterRepository: ref.watch(characterRepositoryProvider),
    importService: ref.watch(live2DImportServiceProvider),
  );
});
