import 'dart:io';
import 'dart:typed_data';

import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
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

/// Friends-circle moments: characters post on their own, people can comment.
final class MomentService {
  MomentService({
    required MomentRepository momentRepository,
    required CharacterRepository characterRepository,
    required String dataPath,
    ChatRepository? chatRepository,
    WorldInfoRepository? worldInfoRepository,
    DataBankRepository? dataBank,
    MomentLlmTransport? transport,
    MomentImageGenerator? imageGenerator,
    DateTime Function()? now,
    String Function()? createId,
    this.minInterval = defaultMinInterval,
    this.maxPostsPerSweep = defaultMaxPostsPerSweep,
  })  : _moments = momentRepository,
        _characters = characterRepository,
        _chats = chatRepository,
        _worldInfo = worldInfoRepository,
        _dataBank = dataBank,
        _transport = transport,
        _imageGenerator = imageGenerator,
        _dataPath = dataPath,
        _now = now ?? (() => DateTime.now().toUtc()),
        _createId = createId ?? const Uuid().v4;

  static const userAuthorId = 'user';
  static const userAuthorName = 'You';
  static const defaultMinInterval = Duration(minutes: 30);
  static const defaultMaxPostsPerSweep = 3;

  final MomentRepository _moments;
  final CharacterRepository _characters;
  final ChatRepository? _chats;
  final WorldInfoRepository? _worldInfo;
  final DataBankRepository? _dataBank;
  final MomentLlmTransport? _transport;
  final MomentImageGenerator? _imageGenerator;
  final String _dataPath;
  final DateTime Function() _now;
  final String Function() _createId;
  final Duration minInterval;
  final int maxPostsPerSweep;

  Future<List<MomentFeedItem>> loadFeed() async {
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
  }) {
    return createPost(
      authorId: userAuthorId,
      authorName: userAuthorName,
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
    return _moments.create(
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
  }) {
    return _moments.addComment(
      MomentComment(
        id: _createId(),
        postId: postId,
        authorId: authorId,
        authorName: authorName,
        body: body,
        createdAt: _now(),
      ),
    );
  }

  /// Characters decide whether to post from their card, bound knowledge, and chats.
  Future<List<MomentPost>> maybePublishCharacterMoments({
    required LLMConfig config,
    String? onlyCharacterId,
  }) async {
    if (_transport == null || !isMemoryLlmConfigured(config)) {
      return const [];
    }

    final characters = onlyCharacterId == null
        ? await _characters.getAllCharacters()
        : [
            if (await _characters.getCharacter(onlyCharacterId)
                case final character?)
              character,
          ];
    if (characters.isEmpty) return const [];

    final feed = List<MomentPost>.from(await _moments.listAll());
    final published = <MomentPost>[];
    for (final character in characters) {
      if (published.length >= maxPostsPerSweep) break;
      final ownPosts = feed
          .where((post) => post.authorId == character.id)
          .toList(growable: false);
      final context = await _loadContext(character);
      if (!_shouldConsider(ownPosts, context)) continue;

      final post = await _publishFromCharacter(
        character: character,
        context: context,
        ownPosts: ownPosts,
        config: config,
      );
      if (post != null) {
        published.add(post);
        feed.insert(0, post);
      }
    }
    return published;
  }

  Future<List<MomentPost>> maybePublishAfterChat({
    required String characterId,
    required LLMConfig config,
  }) {
    return maybePublishCharacterMoments(
      config: config,
      onlyCharacterId: characterId,
    );
  }

  bool _shouldConsider(
    List<MomentPost> ownPosts,
    _CharacterMomentContext context,
  ) {
    if (!context.hasMaterial) return false;
    if (ownPosts.isEmpty) return true;
    final latest = ownPosts.first;
    if (_now().difference(latest.createdAt) < minInterval) return false;
    final lastChatAt = context.lastChatAt;
    if (lastChatAt == null) return false;
    return lastChatAt.isAfter(latest.createdAt);
  }

  Future<MomentPost?> _publishFromCharacter({
    required Character character,
    required _CharacterMomentContext context,
    required List<MomentPost> ownPosts,
    required LLMConfig config,
  }) async {
    final transport = _transport;
    if (transport == null) return null;
    String raw;
    try {
      raw = await transport(
        composeMomentMessages(
          characterName: _displayName(character),
          characterCard: context.characterCard,
          knowledge: context.knowledge,
          conversations: context.conversations,
          recentPosts: ownPosts
              .take(3)
              .map((post) => post.publicBody)
              .where((body) => body.isNotEmpty)
              .join('\n'),
        ),
        config,
      );
    } catch (_) {
      return null;
    }

    MomentDraft? draft;
    try {
      draft = parseMomentDraft(raw);
    } on FormatException {
      return null;
    }
    if (draft == null) return null;

    String? imagePath;
    if (draft.wantsPhoto) {
      imagePath = await _generatePhoto(draft.imagePrompt!);
      if (imagePath == null && !draft.hasBody) return null;
    }
    if (!draft.hasBody && imagePath == null) return null;

    return createPost(
      authorId: character.id,
      authorName: _displayName(character),
      origin: MomentPostOrigin.character,
      body: draft.body,
      imagePath: imagePath,
    );
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
    return _CharacterMomentContext(
      characterCard: card,
      knowledge: knowledge.text,
      conversations: conversation.text,
      lastChatAt: conversation.lastAt,
      hasMaterial: card.isNotEmpty ||
          knowledge.text.isNotEmpty ||
          conversation.text.isNotEmpty,
    );
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
    required this.lastChatAt,
    required this.hasMaterial,
  });

  final String characterCard;
  final String knowledge;
  final String conversations;
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
