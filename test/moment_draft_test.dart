import 'package:flutter_test/flutter_test.dart';
import 'package:native_tavern/domain/services/moment_draft.dart';

void main() {
  test('compose messages ask the character to post as themselves', () {
    final messages = composeMomentMessages(
      characterName: 'Ava',
      characterCard: 'name: Ava\npersonality: dry',
      knowledge: 'Keeps a spare key under the pot.',
      conversations: 'User: Did you lock the gate?\nAva: Of course.',
      recentPosts: 'The garden is quiet tonight.',
    );

    expect(messages, hasLength(2));
    expect(messages.first['role'], 'system');
    expect(messages.first['content'], contains('Ava'));
    expect(messages.first['content'], contains('friends-circle'));
    expect(messages.last['content'], contains('spare key'));
    expect(messages.last['content'], contains('lock the gate'));
  });

  test('parseMomentDraft accepts text, photo, and skip', () {
    expect(
      parseMomentDraft('{"kind":"text","body":"Locked it."}')!.body,
      'Locked it.',
    );
    expect(
      parseMomentDraft(
        '{"kind":"text_image","body":"Look.","image_prompt":"a rusted gate"}',
      )!.wantsPhoto,
      isTrue,
    );
    expect(parseMomentDraft('{"skip":true}'), isNull);
    expect(parseMomentDraft('{"kind":"text","body":""}'), isNull);
  });
}
