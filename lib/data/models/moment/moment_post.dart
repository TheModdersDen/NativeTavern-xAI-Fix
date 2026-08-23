import 'package:equatable/equatable.dart';

enum MomentPostOrigin { chapter, user }

enum MomentPostStatus { open, waiting, ignored }

enum MomentCommentKind { comment, expose, character }

/// A public moment. The chapter summary is the private fact; [publicBody]
/// is what the author chose to show.
class MomentPost extends Equatable {
  final String id;
  final String chatId;
  final String authorId;
  final String authorName;
  final String publicBody;
  final String? factBody;
  final String? chapterId;
  final MomentPostOrigin origin;
  final MomentPostStatus status;
  final bool writeToWorld;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MomentPost._({
    required this.id,
    required this.chatId,
    required this.authorId,
    required this.authorName,
    required this.publicBody,
    required this.factBody,
    required this.chapterId,
    required this.origin,
    required this.status,
    required this.writeToWorld,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MomentPost({
    required String id,
    required String chatId,
    required String authorId,
    required String authorName,
    required String publicBody,
    String? factBody,
    String? chapterId,
    MomentPostOrigin origin = MomentPostOrigin.user,
    MomentPostStatus status = MomentPostStatus.open,
    bool writeToWorld = false,
    required DateTime createdAt,
    DateTime? updatedAt,
  }) {
    _requireNonEmpty(id, 'id');
    _requireNonEmpty(chatId, 'chatId');
    _requireNonEmpty(authorId, 'authorId');
    _requireNonEmpty(authorName, 'authorName');
    _requireNonEmpty(publicBody, 'publicBody');
    if (origin == MomentPostOrigin.chapter &&
        (chapterId == null || chapterId.trim().isEmpty)) {
      throw ArgumentError('Chapter posts require a chapterId.');
    }
    final effectiveUpdatedAt = updatedAt ?? createdAt;
    if (effectiveUpdatedAt.isBefore(createdAt)) {
      throw ArgumentError('updatedAt cannot be before createdAt.');
    }
    return MomentPost._(
      id: id,
      chatId: chatId,
      authorId: authorId,
      authorName: authorName.trim(),
      publicBody: publicBody.trim(),
      factBody: factBody?.trim().isEmpty == true ? null : factBody?.trim(),
      chapterId: chapterId,
      origin: origin,
      status: status,
      writeToWorld: writeToWorld,
      createdAt: createdAt,
      updatedAt: effectiveUpdatedAt,
    );
  }

  bool get hasHiddenFact =>
      factBody != null && factBody!.isNotEmpty && factBody != publicBody;

  MomentPost copyWith({
    String? id,
    String? chatId,
    String? authorId,
    String? authorName,
    String? publicBody,
    String? factBody,
    bool clearFactBody = false,
    String? chapterId,
    MomentPostOrigin? origin,
    MomentPostStatus? status,
    bool? writeToWorld,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MomentPost(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      publicBody: publicBody ?? this.publicBody,
      factBody: clearFactBody ? null : (factBody ?? this.factBody),
      chapterId: chapterId ?? this.chapterId,
      origin: origin ?? this.origin,
      status: status ?? this.status,
      writeToWorld: writeToWorld ?? this.writeToWorld,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'chatId': chatId,
        'authorId': authorId,
        'authorName': authorName,
        'publicBody': publicBody,
        if (factBody != null) 'factBody': factBody,
        if (chapterId != null) 'chapterId': chapterId,
        'origin': origin.name,
        'status': status.name,
        'writeToWorld': writeToWorld,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  @override
  List<Object?> get props => [
        id,
        chatId,
        authorId,
        authorName,
        publicBody,
        factBody,
        chapterId,
        origin,
        status,
        writeToWorld,
        createdAt,
        updatedAt,
      ];
}

class MomentComment extends Equatable {
  final String id;
  final String postId;
  final String authorId;
  final String authorName;
  final String body;
  final MomentCommentKind kind;
  final DateTime createdAt;

  const MomentComment._({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.kind,
    required this.createdAt,
  });

  factory MomentComment({
    required String id,
    required String postId,
    required String authorId,
    required String authorName,
    required String body,
    MomentCommentKind kind = MomentCommentKind.comment,
    required DateTime createdAt,
  }) {
    _requireNonEmpty(id, 'id');
    _requireNonEmpty(postId, 'postId');
    _requireNonEmpty(authorId, 'authorId');
    _requireNonEmpty(authorName, 'authorName');
    _requireNonEmpty(body, 'body');
    return MomentComment._(
      id: id,
      postId: postId,
      authorId: authorId,
      authorName: authorName.trim(),
      body: body.trim(),
      kind: kind,
      createdAt: createdAt,
    );
  }

  @override
  List<Object?> get props => [
        id,
        postId,
        authorId,
        authorName,
        body,
        kind,
        createdAt,
      ];
}

void _requireNonEmpty(String value, String fieldName) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be empty');
  }
}
