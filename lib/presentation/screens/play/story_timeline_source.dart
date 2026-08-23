import 'package:native_tavern/domain/services/story_query_service.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';

/// Chapter list used by the story page.
abstract interface class StoryTimelineSource {
  Future<List<StoryChapterTimelineItem>> listChapters();
}

final class RepositoryStoryTimelineSource implements StoryTimelineSource {
  const RepositoryStoryTimelineSource(this._query);

  final StoryQueryService _query;

  @override
  Future<List<StoryChapterTimelineItem>> listChapters() async {
    final chapters = await _query.listRecent();
    return [
      for (final chapter in chapters)
        StoryChapterTimelineItem(
          id: chapter.id,
          chatId: chapter.chatId,
          title: chapter.title,
          summary: chapter.summary,
          jumpMessageId: chapter.jumpMessageId,
          createdAt: chapter.createdAt,
        ),
    ];
  }
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
