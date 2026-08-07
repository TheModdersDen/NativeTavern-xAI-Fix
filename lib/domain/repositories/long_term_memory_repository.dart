import 'package:native_tavern/data/models/long_term_memory.dart';

/// Storage-independent operations required by the long-term memory feature.
abstract interface class LongTermMemoryRepository {
  Future<LongTermMemory?> getById(String id);

  Future<LongTermMemory> create(LongTermMemory memory);

  Future<LongTermMemory> update(LongTermMemory memory);

  Future<void> delete(String id);

  /// Finds memories in an exact owner scope.
  Future<List<LongTermMemory>> findByScope(
    MemoryScope scope, {
    Set<MemoryState> states = const <MemoryState>{},
    bool includeExpired = false,
    DateTime? at,
  });

  /// Finds memories citing a chat, optionally narrowed to one message.
  Future<List<LongTermMemory>> findBySource({
    required String chatId,
    String? messageId,
  });

  /// Applies one lifecycle state to a group of records atomically.
  ///
  /// [supersededByMemoryId] is required only when [state] is superseded.
  Future<void> updateStates({
    required Set<String> memoryIds,
    required MemoryState state,
    String? supersededByMemoryId,
  });
}
