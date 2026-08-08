import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/domain/services/chat_generation_pipeline.dart';

final chatExtensionRegistryProvider = Provider<ChatExtensionRegistry>((ref) {
  final registry = ChatExtensionRegistry();
  ref.onDispose(registry.clear);
  return registry;
});

final lastContextAssemblyProvider =
    StateProvider<ContextAssemblyResult?>((ref) => null);

final lastChatGenerationTraceProvider =
    StateProvider<ChatGenerationTrace?>((ref) => null);

final chatGenerationPipelineProvider = Provider<ChatGenerationPipeline>((ref) {
  final pipeline = ChatGenerationPipeline(
    registry: ref.watch(chatExtensionRegistryProvider),
    onContextAssembled: (result) {
      ref.read(lastContextAssemblyProvider.notifier).state = result;
    },
    onGenerationFinished: (trace) {
      ref.read(lastChatGenerationTraceProvider.notifier).state = trace;
    },
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});
