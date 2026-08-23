import 'dart:convert';

enum MomentDraftKind { text, image, textImage }

/// What a character decided to post on the moments feed.
final class MomentDraft {
  const MomentDraft({
    required this.kind,
    this.body = '',
    this.imagePrompt,
  });

  final MomentDraftKind kind;
  final String body;
  final String? imagePrompt;

  bool get wantsPhoto =>
      kind == MomentDraftKind.image || kind == MomentDraftKind.textImage;

  bool get hasBody => body.trim().isNotEmpty;
}

List<Map<String, dynamic>> composeMomentMessages({
  required String characterName,
  required String characterCard,
  required String knowledge,
  required String conversations,
  required String recentPosts,
  String friends = '',
  String visibleMoments = '',
}) {
  return [
    {
      'role': 'system',
      'content': '''
You are $characterName posting on a friends-circle moments feed.
Speak as yourself. Do not summarize a chapter. Do not write a recap.
You only see your own posts, posts by your friends, posts by the player, and comments on those posts.
You cannot see strangers' moments. You may react to what you can see, but this output is your own post.
Decide whether you have something natural to share right now.

Return JSON only:
{"skip": false, "kind": "text"|"image"|"text_image", "body": "...", "image_prompt": "..."}

Rules:
- kind=text: body required, 1-4 short sentences in your voice.
- kind=image: image_prompt required; body may be empty.
- kind=text_image: body and image_prompt required.
- image_prompt describes the photo you would post. It is not shown to others.
- If nothing feels natural, return {"skip": true}.
''',
    },
    {
      'role': 'user',
      'content': jsonEncode({
        'character': characterCard,
        'knowledge': knowledge,
        'conversations': conversations,
        'friends': friends,
        'visible_moments': visibleMoments,
        'recent_posts': recentPosts,
      }),
    },
  ];
}

List<Map<String, dynamic>> composeFriendCommentMessages({
  required String characterName,
  required String visiblePosts,
}) {
  return [
    {
      'role': 'system',
      'content': '''
You are $characterName commenting on a moments post you can see.
That is a friend's post or the player's post, plus comments already on it.
Speak as yourself. One short comment only. You cannot mention posts you cannot see.

Return JSON only:
{"skip": false, "post_id": "...", "body": "..."}
or {"skip": true}
''',
    },
    {
      'role': 'user',
      'content': jsonEncode({'visible_posts': visiblePosts}),
    },
  ];
}

final class MomentFriendCommentDraft {
  const MomentFriendCommentDraft({required this.postId, required this.body});

  final String postId;
  final String body;
}

MomentFriendCommentDraft? parseFriendCommentDraft(
  String response, {
  required Set<String> allowedPostIds,
}) {
  final document = jsonDecode(_jsonObjectFromResponse(response));
  if (document is! Map<String, dynamic>) return null;
  if (document['skip'] == true) return null;
  final postId = document['post_id'] is String
      ? (document['post_id'] as String).trim()
      : document['postId'] is String
          ? (document['postId'] as String).trim()
          : '';
  final body = document['body'] is String
      ? (document['body'] as String).trim()
      : '';
  if (postId.isEmpty || body.isEmpty || !allowedPostIds.contains(postId)) {
    return null;
  }
  return MomentFriendCommentDraft(postId: postId, body: _clip(body, 200));
}

MomentDraft? parseMomentDraft(String response) {
  final document = jsonDecode(_jsonObjectFromResponse(response));
  if (document is! Map<String, dynamic>) return null;
  if (document['skip'] == true) return null;

  final kind = _kind(document['kind']);
  if (kind == null) return null;
  final body = document['body'] is String
      ? (document['body'] as String).trim()
      : '';
  final imagePrompt = document['image_prompt'] is String
      ? (document['image_prompt'] as String).trim()
      : document['imagePrompt'] is String
          ? (document['imagePrompt'] as String).trim()
          : '';
  final effectivePrompt = imagePrompt.isEmpty ? null : imagePrompt;

  switch (kind) {
    case MomentDraftKind.text:
      if (body.isEmpty) return null;
      return MomentDraft(kind: kind, body: _clip(body, 500));
    case MomentDraftKind.image:
      if (effectivePrompt == null) return null;
      return MomentDraft(
        kind: kind,
        body: _clip(body, 500),
        imagePrompt: _clip(effectivePrompt, 800),
      );
    case MomentDraftKind.textImage:
      if (body.isEmpty || effectivePrompt == null) return null;
      return MomentDraft(
        kind: kind,
        body: _clip(body, 500),
        imagePrompt: _clip(effectivePrompt, 800),
      );
  }
}

MomentDraftKind? _kind(Object? value) {
  if (value is! String) return null;
  switch (value.trim()) {
    case 'text':
      return MomentDraftKind.text;
    case 'image':
      return MomentDraftKind.image;
    case 'text_image':
    case 'textImage':
    case 'photo':
      return MomentDraftKind.textImage;
    default:
      return null;
  }
}

String _jsonObjectFromResponse(String response) {
  final trimmed = response.trim();
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw const FormatException('Response does not contain JSON.');
  }
  return trimmed.substring(start, end + 1);
}

String _clip(String value, int max) {
  if (value.length <= max) return value;
  return value.substring(0, max).trim();
}
