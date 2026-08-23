import 'dart:io';

import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/repositories/moment_repository.dart';
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

final class MomentAuthor {
  const MomentAuthor({
    required this.id,
    required this.name,
    required this.origin,
  });

  final String id;
  final String name;
  final MomentPostOrigin origin;
}

/// Friends-circle moments: people post text or a photo, others comment.
final class MomentService {
  MomentService({
    required MomentRepository momentRepository,
    required CharacterRepository characterRepository,
    required String dataPath,
    DateTime Function()? now,
    String Function()? createId,
  })  : _moments = momentRepository,
        _characters = characterRepository,
        _dataPath = dataPath,
        _now = now ?? (() => DateTime.now().toUtc()),
        _createId = createId ?? const Uuid().v4;

  static const userAuthorId = 'user';
  static const userAuthorName = 'You';

  final MomentRepository _moments;
  final CharacterRepository _characters;
  final String _dataPath;
  final DateTime Function() _now;
  final String Function() _createId;

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

  Future<List<MomentAuthor>> composeAuthors() async {
    final characters = await _characters.getAllCharacters();
    return [
      const MomentAuthor(
        id: userAuthorId,
        name: userAuthorName,
        origin: MomentPostOrigin.user,
      ),
      ...characters.map(
        (character) => MomentAuthor(
          id: character.id,
          name: character.name.trim().isEmpty ? 'Someone' : character.name,
          origin: MomentPostOrigin.character,
        ),
      ),
    ];
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
    final directory = Directory(p.join(_dataPath, 'moments'));
    await directory.create(recursive: true);
    final extension = p.extension(sourcePath);
    final destination = p.join(directory.path, '${_createId()}$extension');
    await source.copy(destination);
    return destination;
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
}
