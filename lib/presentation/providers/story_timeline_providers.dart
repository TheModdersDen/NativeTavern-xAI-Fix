import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';
import 'package:native_tavern/presentation/screens/play/story_timeline_source.dart';

/// Override in tests (or after #65) to supply real chapters.
final storyTimelineSourceProvider = Provider<StoryTimelineSource>((ref) {
  return const EmptyStoryTimelineSource();
});

final storyTimelineProvider =
    FutureProvider<List<StoryChapterTimelineItem>>((ref) {
  return ref.watch(storyTimelineSourceProvider).listChapters();
});
