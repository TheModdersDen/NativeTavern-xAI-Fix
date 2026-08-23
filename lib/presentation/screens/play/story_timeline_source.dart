import 'package:native_tavern/presentation/screens/play/story_models.dart';

/// Chapter list used by the story page.
///
/// #65 owns persistence. Until that API lands, the default source is empty
/// and tests inject fake chapters.
abstract interface class StoryTimelineSource {
  Future<List<StoryChapterTimelineItem>> listChapters();
}

final class EmptyStoryTimelineSource implements StoryTimelineSource {
  const EmptyStoryTimelineSource();

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async => const [];
}

final class FakeStoryTimelineSource implements StoryTimelineSource {
  const FakeStoryTimelineSource(this.chapters);

  final List<StoryChapterTimelineItem> chapters;

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async =>
      List<StoryChapterTimelineItem>.unmodifiable(chapters);
}
