import 'package:native_tavern/data/models/moment/moment_post.dart';

/// Storage-independent operations for the public moments feed.
abstract interface class MomentRepository {
  Future<MomentPost?> getById(String id);

  Future<MomentPost> create(MomentPost post);

  Future<MomentPost> update(MomentPost post);

  Future<void> delete(String id);

  /// Posts for [chatId], including surviving chapter posts.
  Future<List<MomentPost>> listByChatId(String chatId);

  Future<List<MomentPost>> listAll();

  Future<MomentPost?> findByChapterId(String chapterId);

  Future<MomentComment> addComment(MomentComment comment);

  Future<List<MomentComment>> listComments(String postId);
}
