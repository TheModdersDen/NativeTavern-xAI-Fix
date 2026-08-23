import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
import 'package:native_tavern/domain/repositories/story_repository.dart';
import 'package:uuid/uuid.dart';

final class MomentFeedItem {
  const MomentFeedItem({
    required this.post,
    this.comments = const [],
  });

  final MomentPost post;
  final List<MomentComment> comments;
}

/// Public moments derived from surviving story chapters.
final class MomentService {
  MomentService({
    required MomentRepository momentRepository,
    required StoryRepository storyRepository,
    required ChatRepository chatRepository,
    required CharacterRepository characterRepository,
    DateTime Function()? now,
    String Function()? createId,
  })  : _moments = momentRepository,
        _stories = storyRepository,
        _chats = chatRepository,
        _characters = characterRepository,
        _now = now ?? (() => DateTime.now().toUtc()),
        _createId = createId ?? const Uuid().v4;

  static const userAuthorId = 'user';
  static const userAuthorName = 'You';

  final MomentRepository _moments;
  final StoryRepository _stories;
  final ChatRepository _chats;
  final CharacterRepository _characters;
  final DateTime Function() _now;
  final String Function() _createId;

  Future<List<MomentFeedItem>> loadFeed() async {
    await syncFromChapters();
    final posts = await _moments.listAll();
    final items = <MomentFeedItem>[];
    for (final post in posts) {
      items.add(
        MomentFeedItem(
          post: post,
          comments: await _moments.listComments(post.id),
        ),
      );
    }
    return items;
  }

  Future<List<MomentFeedItem>> loadFeedForChat(String chatId) async {
    await syncFromChapters(chatId: chatId);
    final posts = await _moments.listByChatId(chatId);
    final items = <MomentFeedItem>[];
    for (final post in posts) {
      items.add(
        MomentFeedItem(
          post: post,
          comments: await _moments.listComments(post.id),
        ),
      );
    }
    return items;
  }

  Future<void> syncFromChapters({String? chatId}) async {
    final chats = chatId == null
        ? await _chats.getAllChats()
        : [
            if (await _chats.getChat(chatId) case final chat?) chat,
          ];
    for (final chat in chats) {
      final chapters = await _stories.listByChatId(chat.id);
      final character = await _characters.getCharacter(chat.characterId);
      final authorName = character?.name.trim().isNotEmpty == true
          ? character!.name
          : 'Someone';
      for (final chapter in chapters) {
        final existing = await _moments.findByChapterId(chapter.id);
        if (existing != null) continue;
        if (_looksLikeFiller(chapter)) continue;
        await _moments.create(
          MomentPost(
            id: _createId(),
            chatId: chat.id,
            authorId: chat.characterId,
            authorName: authorName,
            publicBody: _publicSpin(chapter),
            factBody: chapter.summary,
            chapterId: chapter.id,
            origin: MomentPostOrigin.chapter,
            createdAt: _now(),
          ),
        );
      }
    }
  }

  Future<MomentPost> createUserPost({
    required String chatId,
    required String body,
    bool waiting = false,
    bool writeToWorld = false,
  }) {
    return _moments.create(
      MomentPost(
        id: _createId(),
        chatId: chatId,
        authorId: userAuthorId,
        authorName: userAuthorName,
        publicBody: body,
        origin: MomentPostOrigin.user,
        status: waiting ? MomentPostStatus.waiting : MomentPostStatus.open,
        writeToWorld: writeToWorld,
        createdAt: _now(),
      ),
    );
  }

  Future<MomentComment> comment({
    required String postId,
    required String body,
    String authorId = userAuthorId,
    String authorName = userAuthorName,
  }) async {
    final post = await _requirePost(postId);
    final comment = await _moments.addComment(
      MomentComment(
        id: _createId(),
        postId: post.id,
        authorId: authorId,
        authorName: authorName,
        body: body,
        createdAt: _now(),
      ),
    );
    if (post.status == MomentPostStatus.waiting) {
      await _moments.update(
        post.copyWith(status: MomentPostStatus.open, updatedAt: _now()),
      );
    }
    return comment;
  }

  Future<MomentComment> expose(String postId) async {
    final post = await _requirePost(postId);
    final fact = post.factBody;
    if (fact == null || fact.isEmpty) {
      throw StateError('This post has no chapter fact to expose.');
    }
    final now = _now();
    final userComment = await _moments.addComment(
      MomentComment(
        id: _createId(),
        postId: post.id,
        authorId: userAuthorId,
        authorName: userAuthorName,
        body: 'That is not what happened. $fact',
        kind: MomentCommentKind.expose,
        createdAt: now,
      ),
    );
    await _moments.addComment(
      MomentComment(
        id: _createId(),
        postId: post.id,
        authorId: post.authorId,
        authorName: post.authorName,
        body: 'I cannot deny it. $fact',
        kind: MomentCommentKind.character,
        createdAt: now.add(const Duration(milliseconds: 1)),
      ),
    );
    await _moments.update(
      post.copyWith(
        publicBody: fact,
        status: MomentPostStatus.open,
        updatedAt: now,
      ),
    );
    return userComment;
  }

  Future<MomentPost> markIgnored(String postId) async {
    final post = await _requirePost(postId);
    return _moments.update(
      post.copyWith(status: MomentPostStatus.ignored, updatedAt: _now()),
    );
  }

  Future<String> conversationSeed(String postId) async {
    final post = await _requirePost(postId);
    final buffer = StringBuffer('About your moment: "${post.publicBody}"');
    if (post.hasHiddenFact) {
      buffer.write(' I know what actually happened.');
    }
    return buffer.toString();
  }

  Future<String?> jumpTargetForPost(String postId) async {
    final post = await _requirePost(postId);
    final chapterId = post.chapterId;
    if (chapterId == null) return null;
    final chapter = await _stories.getById(chapterId);
    if (chapter == null) return null;
    final surviving = await _stories.listByChatId(chapter.chatId);
    for (final candidate in surviving) {
      if (candidate.id == chapter.id) return candidate.jumpMessageId;
    }
    return null;
  }

  Future<MomentPost> _requirePost(String id) async {
    final post = await _moments.getById(id);
    if (post == null) throw StateError('Moment $id does not exist.');
    return post;
  }

  static bool _looksLikeFiller(StoryChapter chapter) {
    final text = '${chapter.title} ${chapter.summary}'.toLowerCase();
    const banned = [
      'weather',
      'sunny',
      'rainy',
      'cloudy',
      'mood',
      'feeling fine',
      'how are you',
      '天气',
      '心情',
    ];
    return banned.any(text.contains);
  }

  static String _publicSpin(StoryChapter chapter) {
    final summary = chapter.summary.trim();
    if (summary.isEmpty) return chapter.title;
    if (summary.length <= 80) {
      return 'Nothing worth mentioning. Just ${summary[0].toLowerCase()}${summary.substring(1)}';
    }
    return 'Nothing worth mentioning about ${chapter.title}.';
  }
}
