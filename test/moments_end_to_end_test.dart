import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/character.dart' as models;
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/repositories/character_repository.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/moments_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dataDirectory;
  late CharacterRepository characterRepository;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    dataDirectory = Directory.systemTemp.createTempSync('nt_moments');
    characterRepository = CharacterRepository(database, dataDirectory.path);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        dataPathProvider.overrideWithValue(dataDirectory.path),
        characterRepositoryProvider.overrideWithValue(characterRepository),
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

  test('player and character can both post text', () async {
    final service = container.read(momentServiceProvider);
    final authors = await service.composeAuthors();
    expect(authors.map((author) => author.id), containsAll(['user', 'character-1']));

    await service.createPost(
      authorId: MomentService.userAuthorId,
      authorName: MomentService.userAuthorName,
      origin: MomentPostOrigin.user,
      body: 'Did you lock the gate?',
    );
    await service.createPost(
      authorId: 'character-1',
      authorName: 'Ava',
      origin: MomentPostOrigin.character,
      body: 'Of course I did.',
    );

    final feed = await container.read(momentFeedProvider.future);
    expect(
      feed.map((item) => item.post.publicBody),
      containsAll(<String>['Of course I did.', 'Did you lock the gate?']),
    );
    expect(
      feed.map((item) => item.post.origin),
      containsAll(<MomentPostOrigin>[
        MomentPostOrigin.character,
        MomentPostOrigin.user,
      ]),
    );
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

    await service.comment(postId: created.id, body: 'Nice gate.');
    final feed = await service.loadFeed();
    expect(feed.single.comments.single.body, 'Nice gate.');
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
    await tester.pumpAndSettle();
    expect(find.textContaining('Nobody has posted yet'), findsOneWidget);
    expect(find.text('Waiting for a reply'), findsNothing);
    expect(find.text('Write this into the world'), findsNothing);
    expect(find.text('Expose'), findsNothing);
  });

  testWidgets('compose dialog asks who is posting, not waiting or world writes',
      (tester) async {
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
    await tester.tap(find.byKey(const Key('moments-compose')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('moments-compose-author')), findsOneWidget);
    expect(find.byKey(const Key('moments-compose-photo')), findsOneWidget);
    expect(find.text('Waiting for a reply'), findsNothing);
    expect(find.text('Write this into the world'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('moments-compose-body')),
      'Evening in the garden.',
    );
    await tester.tap(find.byKey(const Key('moments-compose-send')));
    await tester.pumpAndSettle();

    expect(find.text('Evening in the garden.'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });
}
