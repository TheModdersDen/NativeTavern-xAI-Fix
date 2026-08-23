import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/chat.dart' as models_chat;
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/models/story/story_chapter.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/providers/story_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/moments_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late ChatRepository chatRepository;
  late CharacterRepository characterRepository;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataDirectory = Directory.systemTemp.createTempSync('nt_moments');
    chatRepository = ChatRepository(database);
    characterRepository = CharacterRepository(database, dataDirectory.path);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
        chatRepositoryProvider.overrideWithValue(chatRepository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    container.read(appSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final now = DateTime.now();
    await characterRepository.createCharacter(
      models.Character(
        id: 'character-1',
        name: 'Ava',
        createdAt: now,
        modifiedAt: now,
      ),
    );
    await chatRepository.createChat(
      models_chat.Chat(
        id: 'chat-1',
        characterId: 'character-1',
        title: 'Garden',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chatRepository.addMessage(
      models_chat.ChatMessage(
        id: 'm1',
        chatId: 'chat-1',
        role: models_chat.MessageRole.user,
        content: 'We argued in the garden.',
        timestamp: now,
      ),
    );
    await chatRepository.addMessage(
      models_chat.ChatMessage(
        id: 'm2',
        chatId: 'chat-1',
        role: models_chat.MessageRole.assistant,
        content: 'I slammed the gate.',
        timestamp: now.add(const Duration(seconds: 1)),
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  Future<StoryChapter> addChapter({
    String id = 'chapter-1',
    String title = 'The argument',
    String summary = 'They argued in the garden and slammed the gate.',
    String endMessageId = 'm2',
    int endOrdinal = 1,
  }) {
    return container.read(storyRepositoryProvider).create(
          StoryChapter(
            id: id,
            chatId: 'chat-1',
            title: title,
            summary: summary,
            startMessageId: 'm1',
            endMessageId: endMessageId,
            startOrdinal: 0,
            endOrdinal: endOrdinal,
            createdAt: DateTime.utc(2026, 8, 23),
          ),
        );
  }

  test('disabled moments stay empty even when chapters exist', () async {
    await addChapter();
    expect(container.read(appSettingsProvider).momentsEnabled, isFalse);
    expect(await container.read(momentFeedProvider.future), isEmpty);
    expect(await container.read(momentRepositoryProvider).listAll(), isEmpty);
  });

  test('enabled feed derives a public spin and can expose the fact', () async {
    await addChapter();
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(true);
    final feed = await container.read(momentFeedProvider.future);
    expect(feed, hasLength(1));
    final post = feed.single.post;
    expect(post.origin, MomentPostOrigin.chapter);
    expect(post.publicBody, isNot(post.factBody));
    expect(post.hasHiddenFact, isTrue);

    await container.read(momentServiceProvider).expose(post.id);
    container.invalidate(momentFeedProvider);
    final after = await container.read(momentFeedProvider.future);
    expect(after.single.post.publicBody, post.factBody);
    expect(
      after.single.comments.map((comment) => comment.body),
      contains(contains('I cannot deny it')),
    );
    expect(
      await container.read(momentServiceProvider).conversationSeed(post.id),
      contains(post.factBody),
    );
    expect(
      await container.read(momentServiceProvider).jumpTargetForPost(post.id),
      'm1',
    );
  });

  test('weather filler does not become a moment', () async {
    await addChapter(
      title: 'Sunny weather',
      summary: 'The weather was sunny and the mood was fine.',
    );
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(true);
    expect(await container.read(momentFeedProvider.future), isEmpty);
  });

  test('bookmark fork hides the old chapter post', () async {
    await addChapter();
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(true);
    expect(await container.read(momentFeedProvider.future), hasLength(1));
    await chatRepository.deleteMessage('m2');
    container.invalidate(momentFeedProvider);
    expect(await container.read(momentFeedProvider.future), isEmpty);
  });

  test('user can post, wait, comment, and leave unread', () async {
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(true);
    final created = await container.read(momentServiceProvider).createUserPost(
          chatId: 'chat-1',
          body: 'Did you lock the gate?',
          waiting: true,
        );
    expect(created.status, MomentPostStatus.waiting);
    await container.read(momentServiceProvider).comment(
          postId: created.id,
          body: 'I saw it.',
        );
    var feed = await container.read(momentServiceProvider).loadFeed();
    expect(feed.single.post.status, MomentPostStatus.open);
    await container.read(momentServiceProvider).markIgnored(created.id);
    feed = await container.read(momentServiceProvider).loadFeed();
    expect(feed.single.post.status, MomentPostStatus.ignored);
  });

  testWidgets('moments page stays empty until the switch is on', (tester) async {
    await addChapter();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: AppRoutes.playMoments,
                builder: (_, __) => const MomentsScreen(),
              ),
            ],
            initialLocation: AppRoutes.playMoments,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('stay empty'), findsOneWidget);

    await tester.tap(find.byKey(const Key('moments-enabled-switch')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing worth mentioning'), findsOneWidget);
    expect(find.textContaining('What actually happened'), findsOneWidget);
    expect(find.byKey(Key('moment-expose-moment-missing')), findsNothing);
    expect(find.text('Expose'), findsOneWidget);
  });
}
