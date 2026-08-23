import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart' hide Chat, Message;
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/models/chat.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/character/character_detail_screen.dart';
import 'package:native_tavern/presentation/screens/play/moments_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late CharacterRepository characterRepository;
  late ChatRepository chatRepository;
  late WorldInfoRepository worldInfoRepository;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataDirectory = Directory.systemTemp.createTempSync('nt_moments');
    characterRepository = CharacterRepository(database, dataDirectory.path);
    chatRepository = ChatRepository(database);
    worldInfoRepository = WorldInfoRepository(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
        chatRepositoryProvider.overrideWithValue(chatRepository),
        worldInfoRepositoryProvider.overrideWithValue(worldInfoRepository),
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
        description: 'Keeps the garden and the spare key.',
        personality: 'Dry, careful, a little proud.',
        createdAt: now,
        modifiedAt: now,
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    dataDirectory.deleteSync(recursive: true);
  });

  test('moments stay empty until someone posts', () async {
    expect(container.read(appSettingsProvider).momentsEnabled, isTrue);
    expect(await container.read(momentFeedProvider.future), isEmpty);
  });

  test('characters post from their card, knowledge, and chats', () async {
    final now = DateTime.now();
    final book = await worldInfoRepository.createWorldInfo(
      name: 'Garden book',
      characterId: 'character-1',
    );
    await worldInfoRepository.addEntry(
      worldInfoId: book.id,
      keys: const ['gate'],
      content: 'The iron gate sticks when it rains.',
    );
    await chatRepository.createChat(
      Chat(
        id: 'chat-1',
        characterId: 'character-1',
        title: 'Evening',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chatRepository.addMessage(
      ChatMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        role: MessageRole.user,
        content: 'Did you lock the gate?',
        timestamp: now,
      ),
    );

    final requests = <List<Map<String, dynamic>>>[];
    final service = MomentService(
      momentRepository: container.read(momentRepositoryProvider),
      chatRepository: chatRepository,
      worldInfoRepository: worldInfoRepository,
      dataPath: dataDirectory.path,
      minInterval: Duration.zero,
      transport: (messages, config) async {
        requests.add(messages);
        return '{"kind":"text","body":"Locked it before the rain."}';
      },
    );
    final character = (await characterRepository.getCharacter('character-1'))!;

    final published = await service.considerCharacter(
      character: character,
      config: _configuredLlm,
    );
    expect(published?.authorName, 'Ava');
    expect(published?.origin, MomentPostOrigin.character);
    expect(published?.publicBody, 'Locked it before the rain.');

    final prompt = requests.single.last['content'] as String;
    expect(prompt, contains('Keeps the garden'));
    expect(prompt, contains('iron gate'));
    expect(prompt, contains('Did you lock the gate?'));
  });

  test('a character can post a photo when the image generator returns one',
      () async {
    final service = MomentService(
      momentRepository: container.read(momentRepositoryProvider),
      dataPath: dataDirectory.path,
      minInterval: Duration.zero,
      transport: (messages, config) async {
        return '{"kind":"image","image_prompt":"a locked garden gate"}';
      },
      imageGenerator: (prompt) async {
        expect(prompt, 'a locked garden gate');
        return const [137, 80, 78, 71];
      },
    );

    final character = (await characterRepository.getCharacter('character-1'))!;
    final published = await service.considerCharacter(
      character: character,
      config: _configuredLlm,
    );
    expect(published?.hasPhoto, isTrue);
    expect(published?.publicBody, isEmpty);
    expect(File(published!.imagePath!).existsSync(), isTrue);
  });

  test('player posts only as themselves', () async {
    final service = container.read(momentServiceProvider);
    final created = await service.publishPlayerPost(body: 'Did you lock the gate?');
    expect(created.origin, MomentPostOrigin.user);
    expect(created.authorId, MomentService.userAuthorId);

    final feed = await container.read(momentFeedProvider.future);
    expect(feed.single.post.publicBody, 'Did you lock the gate?');
    expect(feed.single.post.origin, MomentPostOrigin.user);
  });

  test('a photo-only post is enough and comments stay on the card', () async {
    final source = File('${dataDirectory.path}/gate.png')
      ..writeAsBytesSync(const [137, 80, 78, 71]);
    final service = container.read(momentServiceProvider);
    final stored = await service.importImage(source.path);
    expect(File(stored).existsSync(), isTrue);
    expect(stored, isNot(source.path));

    final created = await service.createPost(
      authorId: 'character-1',
      authorName: 'Ava',
      origin: MomentPostOrigin.character,
      imagePath: stored,
    );
    expect(created.publicBody, isEmpty);
    expect(created.hasPhoto, isTrue);

    await service.comment(
      postId: created.id,
      body: 'Nice gate.',
      authorName: 'Lucy',
    );
    final feed = await service.loadFeed();
    expect(feed.single.comments.single.body, 'Nice gate.');
    expect(feed.single.comments.single.authorName, 'Lucy');
  });

  test('turning moments off hides the feed without deleting posts', () async {
    await container.read(momentServiceProvider).createPost(
          authorId: MomentService.userAuthorId,
          authorName: MomentService.userAuthorName,
          origin: MomentPostOrigin.user,
          body: 'Still here.',
        );
    container.read(appSettingsProvider.notifier).updateMomentsEnabled(false);
    expect(await container.read(momentFeedProvider.future), isEmpty);
    expect(await container.read(momentRepositoryProvider).listAll(), hasLength(1));
  });

  testWidgets('tapping a character avatar opens details and chats',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    await chatRepository.createChat(
      Chat(
        id: 'chat-ava',
        characterId: 'character-1',
        title: 'Garden talk',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await container.read(momentServiceProvider).createPost(
          authorId: 'character-1',
          authorName: 'Ava',
          origin: MomentPostOrigin.character,
          body: 'The gate is locked.',
        );

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
              GoRoute(
                path: '/characters/:id',
                builder: (_, state) => CharacterDetailScreen(
                  characterId: state.pathParameters['id']!,
                ),
              ),
            ],
            initialLocation: AppRoutes.playMoments,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('moment-author-character-1')));
    expect(
      (await chatRepository.getChatsForCharacter('character-1'))
          .map((chat) => chat.title),
      contains('Garden talk'),
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Start Chat'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
  });

  testWidgets('moments page is empty until someone posts', (tester) async {
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Nobody has posted yet'), findsOneWidget);
    expect(find.byKey(const Key('moments-compose-author')), findsNothing);
    expect(find.text('Waiting for a reply'), findsNothing);
    expect(find.text('Write this into the world'), findsNothing);
    expect(find.text('Expose'), findsNothing);
  });

  testWidgets('compose dialog is the player posting, not picking a character',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('moments-compose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('moments-compose-author')), findsNothing);
    expect(find.text('Who is posting'), findsNothing);
    expect(find.byKey(const Key('moments-compose-photo')), findsOneWidget);
    expect(find.text('Waiting for a reply'), findsNothing);
    expect(find.text('Write this into the world'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('moments-compose-body')),
      'Evening in the garden.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('moments-compose-send')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Evening in the garden.'), findsWidgets);
    expect(find.text('Me'), findsWidgets);
  });
}

const _configuredLlm = LLMConfig(
  provider: LLMProvider.openai,
  model: 'chat-model',
  apiKey: 'secret',
  apiUrl: 'https://example.com/v1',
  streamEnabled: false,
);
