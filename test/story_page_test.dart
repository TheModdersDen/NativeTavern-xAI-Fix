import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/story_timeline_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';
import 'package:native_tavern/presentation/screens/play/story_screen.dart';
import 'package:native_tavern/presentation/screens/play/story_timeline_source.dart';

void main() {
  Future<AppLocalizations> loadEn() {
    return AppLocalizations.delegate.load(const Locale('en'));
  }

  testWidgets('empty story page is a timeline empty state, not inbox or editor',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final l10n = await loadEn();
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (_, __) => const Scaffold(body: Text('chat-home')),
        ),
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            const EmptyStoryTimelineSource(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.storyEmptyHint), findsOneWidget);
    expect(find.text(l10n.memoryInbox), findsNothing);
    expect(find.text(l10n.settings), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(const Key('story-go-to-chat')));
    await tester.pumpAndSettle();
    expect(find.text('chat-home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chapter tap jumps back to the original chat message',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chapter = StoryChapterTimelineItem(
      id: 'chapter-1',
      chatId: 'chat-42',
      title: 'Harbor dawn',
      summary: 'They left before the tide turned.',
      jumpMessageId: 'msg-7',
      createdAt: DateTime.utc(2026, 8, 23, 10),
    );
    String? openedLocation;
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (context, state) {
            openedLocation = state.uri.toString();
            return Scaffold(
              body: Text('chat:${state.pathParameters['id']}'),
            );
          },
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            FakeStoryTimelineSource([chapter]),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('story-chapter-timeline')), findsOneWidget);
    expect(find.text('Harbor dawn'), findsOneWidget);
    expect(find.textContaining('They left before the tide turned.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-chapter-chapter-1')));
    await tester.pumpAndSettle();
    expect(find.text('chat:chat-42'), findsOneWidget);
    expect(openedLocation, '/chat/chat-42?message=msg-7');
    expect(tester.takeException(), isNull);
  });

  testWidgets('inbox is a secondary destination and jot note stays on story',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final l10n = await loadEn();
    final router = GoRouter(
      initialLocation: AppRoutes.playStory,
      routes: [
        GoRoute(
          path: AppRoutes.playStory,
          builder: (_, __) => const StoryScreen(),
        ),
        GoRoute(
          path: AppRoutes.memoryInbox,
          builder: (_, __) => const Scaffold(body: Text('memory-inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyTimelineSourceProvider.overrideWithValue(
            const EmptyStoryTimelineSource(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('story-jot-note')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('story-jot-note-field')), findsOneWidget);
    expect(find.text(l10n.storyJotNoteHint), findsOneWidget);
    await tester.tap(find.byKey(const Key('story-jot-note-save')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.storyEmptyHint), findsOneWidget);

    await tester.tap(find.byKey(const Key('story-open-inbox')));
    await tester.pumpAndSettle();
    expect(find.text('memory-inbox'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
