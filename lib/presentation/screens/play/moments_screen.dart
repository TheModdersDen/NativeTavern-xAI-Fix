import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
import 'package:native_tavern/data/repositories/chat_repository.dart';
import 'package:native_tavern/domain/services/moment_service.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/providers/moment_providers.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

class MomentsScreen extends ConsumerWidget {
  const MomentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(appSettingsProvider);
    final feed = ref.watch(momentFeedProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.moments),
        actions: [
          Switch(
            key: const Key('moments-enabled-switch'),
            value: settings.momentsEnabled,
            onChanged: (value) =>
                ref.read(appSettingsProvider.notifier).updateMomentsEnabled(
                      value,
                    ),
          ),
        ],
      ),
      floatingActionButton: settings.momentsEnabled
          ? FloatingActionButton.extended(
              key: const Key('moments-compose'),
              onPressed: () => _compose(context, ref),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.momentsCompose),
            )
          : null,
      body: !settings.momentsEnabled
          ? _CenteredMessage(
              l10n.momentsDisabledEmpty,
              key: const Key('moments-disabled-empty'),
            )
          : feed.when(
              data: (items) => items.isEmpty
                  ? _CenteredMessage(
                      l10n.momentsEmpty,
                      key: const Key('moments-empty'),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) => _MomentCard(
                        item: items[index],
                      ),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _CenteredMessage(error.toString()),
            ),
    );
  }

  Future<void> _compose(BuildContext context, WidgetRef ref) async {
    final chats = await ref.read(chatRepositoryProvider).getRecentChats();
    if (!context.mounted) return;
    if (chats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.momentsNeedChat)),
      );
      return;
    }
    final controller = TextEditingController();
    var waiting = false;
    var writeToWorld = false;
    final posted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final l10n = AppLocalizations.of(context);
            return AlertDialog(
              title: Text(l10n.momentsCompose),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('moments-compose-body'),
                    controller: controller,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: l10n.momentsComposeHint,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.momentsWaiting),
                    value: waiting,
                    onChanged: (value) => setState(() => waiting = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.momentsWriteToWorld),
                    value: writeToWorld,
                    onChanged: (value) => setState(() => writeToWorld = value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l10n.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.send),
                ),
              ],
            );
          },
        );
      },
    );
    final body = controller.text.trim();
    controller.dispose();
    if (posted != true || body.isEmpty) return;
    await ref.read(momentServiceProvider).createUserPost(
          chatId: chats.first.id,
          body: body,
          waiting: waiting,
          writeToWorld: writeToWorld,
        );
    ref.invalidate(momentFeedProvider);
  }
}

class _MomentCard extends ConsumerWidget {
  const _MomentCard({required this.item});

  final MomentFeedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final post = item.post;
    return Card(
      key: Key('moment-card-${post.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(post.authorName, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(post.publicBody),
            if (post.hasHiddenFact) ...[
              const SizedBox(height: 8),
              Text(
                l10n.momentsFact(post.factBody!),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (post.status == MomentPostStatus.waiting)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.momentsWaitingBadge),
              ),
            if (post.status == MomentPostStatus.ignored)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.momentsIgnoredBadge),
              ),
            for (final comment in item.comments)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${comment.authorName}: ${comment.body}'),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  key: Key('moment-comment-${post.id}'),
                  onPressed: () => _comment(context, ref, post),
                  child: Text(l10n.momentsComment),
                ),
                TextButton(
                  key: Key('moment-talk-${post.id}'),
                  onPressed: () => _talk(context, ref, post),
                  child: Text(l10n.momentsTalk),
                ),
                if (post.hasHiddenFact)
                  TextButton(
                    key: Key('moment-expose-${post.id}'),
                    onPressed: () async {
                      await ref.read(momentServiceProvider).expose(post.id);
                      ref.invalidate(momentFeedProvider);
                    },
                    child: Text(l10n.momentsExpose),
                  ),
                TextButton(
                  onPressed: () async {
                    await ref.read(momentServiceProvider).markIgnored(post.id);
                    ref.invalidate(momentFeedProvider);
                  },
                  child: Text(l10n.momentsIgnore),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _comment(
    BuildContext context,
    WidgetRef ref,
    MomentPost post,
  ) async {
    final controller = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.momentsComment),
          content: TextField(
            key: const Key('moment-comment-body'),
            controller: controller,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.send),
            ),
          ],
        );
      },
    );
    final body = controller.text.trim();
    controller.dispose();
    if (submitted != true || body.isEmpty) return;
    await ref.read(momentServiceProvider).comment(postId: post.id, body: body);
    ref.invalidate(momentFeedProvider);
  }

  Future<void> _talk(
    BuildContext context,
    WidgetRef ref,
    MomentPost post,
  ) async {
    final seed = await ref.read(momentServiceProvider).conversationSeed(post.id);
    final messageId =
        await ref.read(momentServiceProvider).jumpTargetForPost(post.id);
    if (!context.mounted) return;
    final uri = Uri(
      path: '/chat/${Uri.encodeComponent(post.chatId)}',
      queryParameters: {
        'draft': seed,
        if (messageId != null) 'message': messageId,
      },
    );
    context.push(uri.toString());
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
