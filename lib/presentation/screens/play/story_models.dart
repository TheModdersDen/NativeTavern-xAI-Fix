/// UI-facing chapter row for `/play/story`.
///
/// Shape matches the #65 query contract (`chatId`, title, summary, jump
/// message) so this page can swap from fake data to the real API later.
class StoryChapterTimelineItem {
  final String id;
  final String chatId;
  final String title;
  final String summary;
  final String jumpMessageId;
  final DateTime createdAt;

  const StoryChapterTimelineItem({
    required this.id,
    required this.chatId,
    required this.title,
    required this.summary,
    required this.jumpMessageId,
    required this.createdAt,
  });

  String get chatPath => '/chat/$chatId?message=$jumpMessageId';
}
