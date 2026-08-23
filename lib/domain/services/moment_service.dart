import 'dart:io';
import 'dart:typed_data';

import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/long_term_memory.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/repositories/long_term_memory_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
import 'package:native_tavern/data/models/operation_log.dart';
import 'package:native_tavern/data/repositories/operation_log_repository.dart';
import 'package:native_tavern/domain/services/character_social_service.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/long_term_memory_governance_service.dart';
import 'package:native_tavern/domain/services/moment_draft.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

final class MomentFeedItem {
  const MomentFeedItem({
    required this.post,
    this.comments = const [],
  });

  final MomentPost post;
  final List<MomentComment> comments;
}

typedef MomentLlmTransport = Future<String> Function(
  List<Map<String, dynamic>> messages,
  LLMConfig config,
);

typedef MomentImageGenerator = Future<List<int>?> Function(String prompt);

/// One world-clock attempt: posted, commented, skipped, or failed.
final class MomentWakeResult {
  const MomentWakeResult.skipped()
      : post = null,
        comment = null,
        failed = false;
  const MomentWakeResult.posted(this.post)
      : comment = null,
        failed = false;
  const MomentWakeResult.commented(this.comment)
      : post = null,
        failed = false;
  const MomentWakeResult.failed()
      : post = null,
        comment = null,
        failed = true;

  final MomentPost? post;
  final MomentComment? comment;
  final bool failed;
}

/// Friends-circle moments: characters post on their own, people can comment.
final class MomentService {
  MomentService({
    required MomentRepository momentRepository,
    required String dataPath,
    ChatRepository? chatRepository,
    WorldInfoRepository? worldInfoRepository,
    DataBankRepository? dataBank,
    CharacterSocialService? social,
    OperationLogRepository? operations,
    LongTermMemoryRepository? memories,
    MomentLlmTransport? transport,
    MomentImageGenerator? imageGenerator,
    DateTime Function()? now,
    String Function()? createId,
    this.minInterval = defaultMinInterval,
  })  : _moments = momentRepository,
        _chats = chatRepository,
        _worldInfo = worldInfoRepository,
        _dataBank = dataBank,
        _social = social,
        _operations = operations,
        _memories = memories,
        _transport = transport,
        _imageGenerator = imageGenerator,
        _dataPath = dataPath,
        _now = now ?? (() => DateTime.now().toUtc()),
        _createId = createId ?? const Uuid().v4;

  static const userAuthorId = 'user';
  static const userAuthorName = 'You';
  static const defaultMinInterval = Duration(minutes: 20);

  final MomentRepository _moments;
  final ChatRepository? _chats;
  final WorldInfoRepository? _worldInfo;
  final DataBankRepository? _dataBank;
  final CharacterSocialService? _social;
  final OperationLogRepository? _operations;
  final LongTermMemoryRepository? _memories;
  final MomentLlmTransport? _transport;
  final MomentImageGenerator? _imageGenerator;
  final String _dataPath;
  final DateTime Function() _now;
  final String Function() _createId;
  final Duration minInterval;

  Future<List<MomentFeedItem>> loadFeed() async {
    await rehomeMispostedReplies();
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

  Future<MomentPost> publishPlayerPost({
    String body = '',
    String? imagePath,
    String? authorName,
  }) {
    return createPost(
      authorId: userAuthorId,
      authorName: (authorName == null || authorName.trim().isEmpty)
          ? userAuthorName
          : authorName.trim(),
      origin: MomentPostOrigin.user,
      body: body,
      imagePath: imagePath,
    );
  }

  Future<MomentPost> createPost({
    required String authorId,
    required String authorName,
    required MomentPostOrigin origin,
    String body = '',
    String? imagePath,
  }) async {
    if (origin == MomentPostOrigin.chapter) {
      throw ArgumentError('New posts are written by people, not chapters.');
    }
    final post = await _moments.create(
      MomentPost(
        id: _createId(),
        authorId: authorId,
        authorName: authorName,
        publicBody: body,
        imagePath: imagePath,
        origin: origin,
        createdAt: _now(),
      ),
    );
    await _rememberMoment(
      characterId: authorId,
      kind: MemoryKind.event,
      content: imagePath == null
          ? '$authorName posted on moments: ${body.trim()}'
          : '$authorName posted a photo on moments'
              '${body.trim().isEmpty ? '' : ': ${body.trim()}'}',
      identity: 'moment:${post.id}',
    );
    return post;
  }

  Future<String> importImage(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'image is missing');
    }
    return _writeImage(await source.readAsBytes(), p.extension(sourcePath));
  }

  Future<String> saveImageBytes(List<int> bytes, {String extension = '.png'}) {
    return _writeImage(Uint8List.fromList(bytes), extension);
  }

  Future<MomentComment> comment({
    required String postId,
    required String body,
    String authorId = userAuthorId,
    String authorName = userAuthorName,
  }) async {
    final comment = await _moments.addComment(
      MomentComment(
        id: _createId(),
        postId: postId,
        authorId: authorId,
        authorName: authorName,
        body: body,
        createdAt: _now(),
      ),
    );
    final post = await _moments.getById(postId);
    if (post != null) {
      await _rememberMoment(
        characterId: authorId == userAuthorId ? post.authorId : authorId,
        kind: MemoryKind.event,
        content: '$authorName commented on ${post.authorName}\'s moment: $body',
        identity: 'moment-comment:${comment.id}',
      );
    }
    return comment;
  }

  /// Move standalone character replies onto the player/friend post they
  /// were answering, so they stop looking like their own moments.
  Future<int> rehomeMispostedReplies() async {
    final posts = await _moments.listAll();
    final targets = [
      for (final post in posts)
        if (post.origin == MomentPostOrigin.user || post.authorId == userAuthorId)
          MomentCommentTarget(
            id: post.id,
            body: post.publicBody,
            fromPlayer: true,
          ),
    ];
    if (targets.isEmpty) return 0;

    var moved = 0;
    for (final post in posts) {
      if (post.origin != MomentPostOrigin.character || post.hasPhoto) {
        continue;
      }
      final targetId = bestReplyPostId(post.publicBody, targets: targets);
      if (targetId == null || targetId == post.id) continue;
      final existing = await _moments.listComments(targetId);
      final already = existing.any(
        (comment) =>
            comment.authorId == post.authorId &&
            comment.body.trim() == post.publicBody.trim(),
      );
      if (!already) {
        try {
          await comment(
            postId: targetId,
            body: post.publicBody,
            authorId: post.authorId,
            authorName: post.authorName,
          );
        } catch (_) {
          continue;
        }
      }
      await _moments.delete(post.id);
      moved++;
    }
    return moved;
  }

  Future<void> rememberFriendship({
    required String characterId,
    required String friendName,
  }) {
    return _rememberMoment(
      characterId: characterId,
      kind: MemoryKind.relationship,
      content: 'Friends with $friendName on moments.',
      identity: 'friend:$characterId:$friendName',
    );
  }

  /// One character decides, when the world clock has already woken them.
  Future<MomentPost?> considerCharacter({
    required Character character,
    required LLMConfig config,
  }) async {
    return (await attemptCharacter(character: character, config: config)).post;
  }

  Future<MomentWakeResult> attemptCharacter({
    required Character character,
    required LLMConfig config,
  }) async {
    if (_transport == null || !isMemoryLlmConfigured(config)) {
      return const MomentWakeResult.failed();
    }
    final context = await _loadContext(character);
    final ownPosts = (await _moments.listAll())
        .where((post) => post.authorId == character.id)
        .toList(growable: false);
    final recentlyPosted = ownPosts.isNotEmpty &&
        _now().difference(ownPosts.first.createdAt) < minInterval;
    final commentTargets = await _commentTargets(character);
    if (!context.hasMaterial && commentTargets.isEmpty) {
      return const MomentWakeResult.skipped();
    }
    if (recentlyPosted && commentTargets.isEmpty) {
      return const MomentWakeResult.skipped();
    }
    return _publishFromCharacter(
      character: character,
      context: context,
      ownPosts: ownPosts,
      commentTargets: commentTargets,
      mayPost: !recentlyPosted,
      config: config,
    );
  }

  Future<List<MomentFeedItem>> _commentTargets(Character character) async {
    return [
      for (final item in await visibleFeedFor(character.id, limit: 8))
        if (item.post.authorId != character.id &&
            !item.comments.any((comment) => comment.authorId == character.id))
          item,
    ];
  }

  /// Posts this character can know about: their own, friends', and the player's,
  /// plus comments on those posts. Strangers stay hidden.
  Future<List<MomentFeedItem>> visibleFeedFor(
    String characterId, {
    int limit = 8,
  }) async {
    final friendIds = await _friendIds(characterId);
    final items = <MomentFeedItem>[];
    for (final post in await _moments.listAll()) {
      if (!isPostVisibleTo(
        post,
        viewerId: characterId,
        friendIds: friendIds,
      )) {
        continue;
      }
      items.add(
        MomentFeedItem(
          post: post,
          comments: await _moments.listComments(post.id),
        ),
      );
      if (items.length >= limit) break;
    }
    return items;
  }

  static bool isMomentsKnowledgeMemory(LongTermMemory memory) {
    final key = memory.normalizedIdentityKey;
    if (key.startsWith('moment')) return true;
    return key.startsWith('friend:') &&
        memory.content.toLowerCase().contains('moments');
  }

  static bool isPostVisibleTo(
    MomentPost post, {
    required String viewerId,
    required Set<String> friendIds,
  }) {
    if (post.authorId == viewerId) return true;
    if (post.authorId == userAuthorId || post.origin == MomentPostOrigin.user) {
      return true;
    }
    return friendIds.contains(post.authorId);
  }

  static String formatVisibleMoments(
    Iterable<MomentFeedItem> items, {
    bool includeIds = false,
  }) {
    final blocks = <String>[];
    for (final item in items) {
      final post = item.post;
      final body = post.publicBody.isEmpty
          ? '[photo]'
          : (post.hasPhoto ? '[photo] ${post.publicBody}' : post.publicBody);
      final headline = includeIds
          ? '${post.id} | ${post.authorName}: $body'
          : '${post.authorName}: $body';
      final lines = <String>[headline];
      for (final comment in item.comments) {
        lines.add('  ${comment.authorName}: ${comment.body}');
      }
      blocks.add(lines.join('\n'));
    }
    return blocks.join('\n');
  }

  /// A friend may leave a comment on a visible post instead of posting.
  Future<MomentComment?> considerFriendComment({
    required Character character,
    required LLMConfig config,
  }) async {
    return (await attemptFriendComment(character: character, config: config))
        .comment;
  }

  Future<MomentWakeResult> attemptFriendComment({
    required Character character,
    required LLMConfig config,
  }) async {
    final transport = _transport;
    if (transport == null || !isMemoryLlmConfigured(config)) {
      return const MomentWakeResult.failed();
    }
    final targets = [
      for (final item in await visibleFeedFor(character.id, limit: 8))
        if (item.post.authorId != character.id) item,
    ];
    if (targets.isEmpty) return const MomentWakeResult.skipped();
    final open = [
      for (final item in targets)
        if (!item.comments.any((comment) => comment.authorId == character.id))
          item,
    ];
    if (open.isEmpty) return const MomentWakeResult.skipped();
    final payload = [
      for (final item in open)
        [
          '${item.post.id} | ${item.post.authorName}: ${item.post.publicBody}',
          for (final comment in item.comments)
            '  ${comment.authorName}: ${comment.body}',
        ].join('\n'),
    ].join('\n');
    String raw;
    try {
      raw = await transport(
        composeFriendCommentMessages(
          characterName: _displayName(character),
          visiblePosts: payload,
        ),
        config,
      );
    } catch (_) {
      return const MomentWakeResult.failed();
    }
    MomentFriendCommentDraft? draft;
    try {
      draft = parseFriendCommentDraft(
        raw,
        allowedPostIds: {for (final item in open) item.post.id},
      );
    } on FormatException {
      return const MomentWakeResult.skipped();
    }
    if (draft == null) return const MomentWakeResult.skipped();
    return MomentWakeResult.commented(
      await comment(
        postId: draft.postId,
        body: draft.body,
        authorId: character.id,
        authorName: _displayName(character),
      ),
    );
  }

  Future<MomentWakeResult> _publishFromCharacter({
    required Character character,
    required _CharacterMomentContext context,
    required List<MomentPost> ownPosts,
    required List<MomentFeedItem> commentTargets,
    required bool mayPost,
    required LLMConfig config,
  }) async {
    final transport = _transport;
    if (transport == null) return const MomentWakeResult.failed();
    String raw;
    try {
      raw = await transport(
        composeMomentMessages(
          characterName: _displayName(character),
          characterCard: context.characterCard,
          knowledge: context.knowledge,
          conversations: context.conversations,
          friends: context.friends,
          visibleMoments: context.visibleMoments,
          commentTargets: formatVisibleMoments(
            commentTargets,
            includeIds: true,
          ),
          recentPosts: ownPosts
              .take(3)
              .map((post) => post.publicBody)
              .where((body) => body.isNotEmpty)
              .join('\n'),
          mayPost: mayPost,
        ),
        config,
      );
    } catch (_) {
      return const MomentWakeResult.failed();
    }

    final targets = [
      for (final item in commentTargets)
        MomentCommentTarget(
          id: item.post.id,
          body: item.post.publicBody,
          fromPlayer: item.post.authorId == userAuthorId ||
              item.post.origin == MomentPostOrigin.user,
        ),
    ];
    MomentWakePlan? plan;
    try {
      plan = parseMomentWakePlan(
        raw,
        allowedPostIds: {for (final item in commentTargets) item.post.id},
        targets: targets,
        mayPost: mayPost,
      );
    } on FormatException {
      return const MomentWakeResult.skipped();
    }
    if (plan == null) return const MomentWakeResult.skipped();
    if (plan.comment != null) {
      try {
        return MomentWakeResult.commented(
          await comment(
            postId: plan.comment!.postId,
            body: plan.comment!.body,
            authorId: character.id,
            authorName: _displayName(character),
          ),
        );
      } catch (_) {
        return const MomentWakeResult.failed();
      }
    }
    final draft = plan.draft;
    if (draft == null) return const MomentWakeResult.skipped();

    if (draft.wantsPhoto) {
      final posted = await _generateLoggedPhoto(
        character: character,
        prompt: draft.imagePrompt!,
        body: draft.body,
      );
      if (posted != null) return MomentWakeResult.posted(posted);
      if (_operations != null) return const MomentWakeResult.skipped();
      if (!draft.hasBody) return const MomentWakeResult.failed();
    }
    if (!draft.hasBody) {
      return const MomentWakeResult.skipped();
    }

    return MomentWakeResult.posted(
      await createPost(
        authorId: character.id,
        authorName: _displayName(character),
        origin: MomentPostOrigin.character,
        body: draft.body,
      ),
    );
  }

  Future<MomentPost?> retryImageJob(OperationLog job) async {
    final operations = _operations;
    if (job.kind != OperationKind.momentImage) return null;
    final prompt = '${job.payload['prompt'] ?? ''}'.trim();
    final body = '${job.payload['body'] ?? ''}';
    final authorId = '${job.payload['characterId'] ?? job.subjectId}';
    final authorName = '${job.payload['authorName'] ?? 'Someone'}';
    if (prompt.isEmpty) {
      await operations?.markIncomplete(job, error: 'Image prompt is missing.');
      return null;
    }
    final claimed = operations == null
        ? job
        : await operations.begin(
            kind: OperationKind.momentImage,
            subjectId: job.subjectId,
            payload: job.payload,
          );
    final imagePath = await _generatePhoto(prompt);
    if (imagePath == null) {
      await operations?.markIncomplete(
        claimed,
        error: 'Image generation failed.',
        dueAt: _now().add(Duration(minutes: 1 << (claimed.attempts - 1).clamp(0, 4))),
      );
      return null;
    }
    final post = await createPost(
      authorId: authorId,
      authorName: authorName,
      origin: MomentPostOrigin.character,
      body: body,
      imagePath: imagePath,
    );
    await operations?.markCompleted(claimed);
    return post;
  }

  Future<MomentPost?> _generateLoggedPhoto({
    required Character character,
    required String prompt,
    required String body,
  }) async {
    final operations = _operations;
    final job = await operations?.begin(
      kind: OperationKind.momentImage,
      subjectId: character.id,
      payload: {
        'characterId': character.id,
        'authorName': _displayName(character),
        'prompt': prompt,
        'body': body,
      },
    );
    final imagePath = await _generatePhoto(prompt);
    if (imagePath == null) {
      if (job != null) {
        await operations?.markIncomplete(
          job,
          error: 'Image generation failed.',
          dueAt: _now().add(const Duration(minutes: 1)),
        );
      }
      return null;
    }
    final post = await createPost(
      authorId: character.id,
      authorName: _displayName(character),
      origin: MomentPostOrigin.character,
      body: body,
      imagePath: imagePath,
    );
    if (job != null) await operations?.markCompleted(job);
    return post;
  }

  Future<String?> _generatePhoto(String prompt) async {
    final generator = _imageGenerator;
    if (generator == null) return null;
    try {
      final bytes = await generator(prompt);
      if (bytes == null || bytes.isEmpty) return null;
      return saveImageBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<_CharacterMomentContext> _loadContext(Character character) async {
    final card = _characterCard(character);
    final knowledge = await _knowledgeFor(character);
    final conversation = await _conversationsFor(character);
    final social = await _socialContext(character);
    return _CharacterMomentContext(
      characterCard: card,
      knowledge: knowledge.text,
      conversations: conversation.text,
      friends: social.friends,
      visibleMoments: social.posts,
      lastChatAt: conversation.lastAt,
      hasMaterial: card.isNotEmpty ||
          knowledge.text.isNotEmpty ||
          conversation.text.isNotEmpty ||
          social.friends.isNotEmpty ||
          social.posts.isNotEmpty,
    );
  }

  Future<({String friends, String posts})> _socialContext(
    Character character,
  ) async {
    final social = _social;
    final friends =
        social == null ? const <Character>[] : await social.friendsOf(character.id);
    final posts = formatVisibleMoments(
      await visibleFeedFor(character.id, limit: 6),
    );
    return (friends: friends.map(_displayName).join(', '), posts: posts);
  }

  Future<Set<String>> _friendIds(String characterId) async {
    final social = _social;
    if (social == null) return const {};
    return {
      for (final friend in await social.friendsOf(characterId)) friend.id,
    };
  }

  Future<void> _rememberMoment({
    required String characterId,
    required MemoryKind kind,
    required String content,
    required String identity,
  }) async {
    final memories = _memories;
    if (memories == null ||
        characterId == userAuthorId ||
        content.trim().isEmpty) {
      return;
    }
    try {
      final now = _now();
      await memories.create(
        LongTermMemory(
          id: _createId(),
          kind: kind,
          scope: MemoryScope.character(characterId),
          state: MemoryState.active,
          content: content.trim(),
          source: MemorySource.manual(),
          importance: 0.55,
          confidence: 0.9,
          createdAt: now,
          normalizedIdentityKey: normalizeMemoryIdentity(identity),
        ),
      );
    } catch (_) {}
  }

  String _characterCard(Character character) {
    final lines = <String>[
      'name: ${_displayName(character)}',
      if (character.description.trim().isNotEmpty)
        'description: ${_clip(character.description, 800)}',
      if (character.personality.trim().isNotEmpty)
        'personality: ${_clip(character.personality, 800)}',
      if (character.scenario.trim().isNotEmpty)
        'scenario: ${_clip(character.scenario, 800)}',
    ];
    return lines.join('\n');
  }

  Future<({String text, DateTime? lastAt})> _conversationsFor(
    Character character,
  ) async {
    final chats = _chats;
    if (chats == null) return (text: '', lastAt: null);

    final sessions = (await chats.getAllChats())
        .where(
          (chat) =>
              chat.characterId == character.id ||
              (chat.groupId != null && chat.characterId == character.id),
        )
        .take(3)
        .toList(growable: false);
    if (sessions.isEmpty) return (text: '', lastAt: null);

    DateTime? lastAt;
    final blocks = <String>[];
    for (final chat in sessions) {
      lastAt = _later(lastAt, chat.updatedAt);
      final messages = await chats.getMessages(chat.id);
      if (messages.isEmpty) continue;
      lastAt = _later(lastAt, messages.last.timestamp);
      final recent = messages.length <= 12
          ? messages
          : messages.sublist(messages.length - 12);
      final lines = recent.map((message) {
        final speaker = message.role == MessageRole.user
            ? 'User'
            : (message.characterName?.trim().isNotEmpty == true
                ? message.characterName!
                : _displayName(character));
        return '$speaker: ${_clip(message.content, 240)}';
      });
      blocks.add('Chat "${chat.title}":\n${lines.join('\n')}');
    }
    return (text: blocks.join('\n\n'), lastAt: lastAt);
  }

  Future<({String text})> _knowledgeFor(Character character) async {
    final snippets = <String>[];
    final book = character.characterBook;
    if (book != null) {
      for (final entry in book.entries) {
        if (!entry.enabled || entry.content.trim().isEmpty) continue;
        snippets.add(_clip(entry.content, 400));
        if (snippets.length >= 12) break;
      }
    }

    final worldInfo = _worldInfo;
    if (worldInfo != null) {
      try {
        final books = [
          ...await worldInfo.getWorldInfosForCharacter(character.id),
          ...await _linkedWorldInfos(character, worldInfo),
        ];
        final seen = <String>{};
        for (final book in books) {
          if (!book.enabled || !seen.add(book.id)) continue;
          for (final entry in book.entries) {
            if (!entry.enabled || entry.content.trim().isEmpty) continue;
            if (!entry.appliesToCharacter(character.id, character.tags)) {
              continue;
            }
            snippets.add(_clip(entry.content, 400));
            if (snippets.length >= 12) break;
          }
          if (snippets.length >= 12) break;
        }
      } catch (_) {}
    }

    final dataBank = _dataBank;
    if (dataBank != null) {
      try {
        final bindings = await dataBank.listBindingsForScope(
          DataBankBindingScope.character,
          targetId: character.id,
        );
        for (final binding in bindings.take(6)) {
          final document = await dataBank.getDocument(binding.documentId);
          if (document == null) continue;
          final version = await dataBank.getVersion(document.currentVersionId);
          final name = version?.originalFileName ?? document.id;
          snippets.add('Document: $name');
        }
        final query = character.name.trim().isEmpty
            ? character.description
            : character.name;
        if (query.trim().isNotEmpty) {
          final hits = await dataBank.search(
            query,
            topK: 6,
            filter: DataBankSearchFilter.forContext(characterId: character.id),
          );
          for (final hit in hits) {
            snippets.add('${hit.documentName}: ${_clip(hit.snippet, 400)}');
          }
        }
      } catch (_) {}
    }

    return (text: snippets.take(12).join('\n'));
  }

  Future<List<WorldInfo>> _linkedWorldInfos(
    Character character,
    WorldInfoRepository worldInfo,
  ) async {
    final chats = _chats;
    if (chats == null) return const [];
    final sessions = await chats.getChatsForCharacter(character.id);
    final ids = <String>{
      for (final chat in sessions) ...chat.linkedWorldInfoIds,
    };
    final books = <WorldInfo>[];
    for (final id in ids) {
      final book = await worldInfo.getWorldInfoById(id);
      if (book != null) books.add(book);
    }
    return books;
  }

  Future<String> _writeImage(List<int> bytes, String extension) async {
    final directory = Directory(p.join(_dataPath, 'moments'));
    await directory.create(recursive: true);
    final suffix = extension.trim().isEmpty ? '.png' : extension;
    final destination = p.join(directory.path, '${_createId()}$suffix');
    await File(destination).writeAsBytes(bytes, flush: true);
    return destination;
  }

  String _displayName(Character character) {
    final name = character.name.trim();
    return name.isEmpty ? 'Someone' : name;
  }
}

final class _CharacterMomentContext {
  const _CharacterMomentContext({
    required this.characterCard,
    required this.knowledge,
    required this.conversations,
    this.friends = '',
    this.visibleMoments = '',
    required this.lastChatAt,
    required this.hasMaterial,
  });

  final String characterCard;
  final String knowledge;
  final String conversations;
  final String friends;
  final String visibleMoments;
  final DateTime? lastChatAt;
  final bool hasMaterial;
}

String _clip(String value, int max) {
  final trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.substring(0, max).trim();
}

DateTime? _later(DateTime? current, DateTime candidate) {
  final utc = candidate.toUtc();
  if (current == null || utc.isAfter(current)) return utc;
  return current;
}
