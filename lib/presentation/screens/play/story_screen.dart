import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/story_timeline_providers.dart';
import 'package:native_tavern/presentation/router/app_router.dart';
import 'package:native_tavern/presentation/screens/play/story_models.dart';

/// Story homepage: chapter timeline only. Inbox and notes are secondary.
class StoryScreen extends ConsumerWidget {
  const StoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final chapters = ref.watch(storyTimelineProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.story),
        actions: [
          IconButton(
            key: const Key('story-jot-note'),
            tooltip: l10n.storyJotNote,
            onPressed: () => _showJotNoteSheet(context),
            icon: const Icon(Icons.edit_note_outlined),
          ),
          IconButton(
            key: const Key('story-open-inbox'),
            tooltip: l10n.memoryInbox,
            onPressed: () => context.push(AppRoutes.memoryInbox),
            icon: const Icon(Icons.inbox_outlined),
          ),
        ],
      ),
      body: chapters.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) {
          if (items.isEmpty) {
            return _StoryEmptyState(
              onGoToChat: () => context.go(AppRoutes.home),
            );
          }
          return ListView.separated(
            key: const Key('story-chapter-timeline'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final chapter = items[index];
              return _StoryChapterTile(
                chapter: chapter,
                onTap: () => context.push(chapter.chatPath),
              );
            },
          );
        },
      ),
    );
  }
}

class _StoryEmptyState extends StatelessWidget {
  const _StoryEmptyState({required this.onGoToChat});

  final VoidCallback onGoToChat;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l10n.storyEmptyHint,
              key: const Key('story-empty-hint'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('story-go-to-chat'),
              onPressed: onGoToChat,
              child: Text(l10n.storyGoToChat),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryChapterTile extends StatelessWidget {
  const _StoryChapterTile({
    required this.chapter,
    required this.onTap,
  });

  final StoryChapterTimelineItem chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat.yMMMd().format(chapter.createdAt.toLocal());
    return Card(
      key: Key('story-chapter-${chapter.id}'),
      child: ListTile(
        title: Text(chapter.title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${chapter.summary}\n$date',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

Future<void> _showJotNoteSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.storyJotNote,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('story-jot-note-field'),
              controller: controller,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: l10n.storyJotNoteHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const Key('story-jot-note-save'),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: Text(l10n.save),
              ),
            ),
          ],
        ),
      );
    },
  ).whenComplete(controller.dispose);
}
