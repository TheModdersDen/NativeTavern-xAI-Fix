import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/drift_moment_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
import 'package:native_tavern/domain/services/image_generation_service.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/presentation/providers/data_bank_providers.dart';
import 'package:native_tavern/presentation/providers/image_gen_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

final momentRepositoryProvider = Provider<MomentRepository>((ref) {
  return DriftMomentRepository(ref.watch(databaseProvider));
});

final momentServiceProvider = Provider<MomentService>((ref) {
  return MomentService(
    momentRepository: ref.watch(momentRepositoryProvider),
    characterRepository: ref.watch(characterRepositoryProvider),
    chatRepository: ref.watch(chatRepositoryProvider),
    worldInfoRepository: ref.watch(worldInfoRepositoryProvider),
    dataBank: ref.watch(dataBankRepositoryProvider),
    dataPath: ref.watch(dataPathProvider),
    transport: (messages, config) {
      return ref.read(llmServiceProvider).generate(messages, config);
    },
    imageGenerator: (prompt) async {
      final imageSettings = ref.read(imageGenSettingsProvider);
      if (!imageSettings.enabled) return null;
      final imageService = ref.read(imageGenServiceProvider);
      imageService.updateSettings(imageSettings);
      final result = await imageService.generate(
        ImageGenRequest(
          prompt: prompt,
          negativePrompt: imageSettings.defaultNegativePrompt,
          width: imageSettings.defaultWidth,
          height: imageSettings.defaultHeight,
          steps: imageSettings.defaultSteps,
          cfgScale: imageSettings.defaultCfgScale,
          sampler: imageSettings.defaultSampler,
          scheduler: imageSettings.defaultScheduler,
        ),
      );
      if (result == null || result.images.isEmpty) return null;
      return result.images.first;
    },
  );
});

final momentFeedProvider =
    FutureProvider.autoDispose<List<MomentFeedItem>>((ref) async {
  if (!ref.watch(appSettingsProvider).momentsEnabled) return const [];
  return ref.watch(momentServiceProvider).loadFeed();
});

final momentSweepProvider = FutureProvider.autoDispose<int>((ref) async {
  if (!ref.watch(appSettingsProvider).momentsEnabled) return 0;
  final published =
      await ref.watch(momentServiceProvider).maybePublishCharacterMoments(
            config: ref.watch(llmConfigProvider),
          );
  return published.length;
});
