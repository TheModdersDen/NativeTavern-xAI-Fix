import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/drift_moment_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

final momentRepositoryProvider = Provider<MomentRepository>((ref) {
  return DriftMomentRepository(ref.watch(databaseProvider));
});

final momentServiceProvider = Provider<MomentService>((ref) {
  return MomentService(
    momentRepository: ref.watch(momentRepositoryProvider),
    characterRepository: ref.watch(characterRepositoryProvider),
    dataPath: ref.watch(dataPathProvider),
  );
});

final momentFeedProvider =
    FutureProvider.autoDispose<List<MomentFeedItem>>((ref) async {
  if (!ref.watch(appSettingsProvider).momentsEnabled) return const [];
  return ref.watch(momentServiceProvider).loadFeed();
});
