import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_tavern/data/models/moment/moment_post.dart';
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
    final authors = await ref.read(momentServiceProvider).composeAuthors();
    if (!context.mounted || authors.isEmpty) return;
    final draft = await showDialog<_ComposeDraft>(
      context: context,
      builder: (dialogContext) => _ComposeDialog(authors: authors),
    );
    if (draft == null || !context.mounted) return;
    final service = ref.read(momentServiceProvider);
    final imagePath = draft.imagePath == null
        ? null
        : await service.importImage(draft.imagePath!);
    await service.createPost(
      authorId: draft.author.id,
      authorName: draft.author.name,
      origin: draft.author.origin,
      body: draft.body,
      imagePath: imagePath,
    );
    ref.invalidate(momentFeedProvider);
  }
}

class _ComposeDraft {
  const _ComposeDraft({
    required this.author,
    required this.body,
    this.imagePath,
  });

  final MomentAuthor author;
  final String body;
  final String? imagePath;
}

class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({required this.authors});

  final List<MomentAuthor> authors;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  late MomentAuthor _author = widget.authors.first;
  final _controller = TextEditingController();
  String? _imagePath;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.momentsCompose),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('moments-compose-author'),
              initialValue: _author.id,
              decoration: InputDecoration(labelText: l10n.momentsAuthor),
              items: [
                for (final author in widget.authors)
                  DropdownMenuItem(
                    value: author.id,
                    child: Text(author.origin == MomentPostOrigin.user
                        ? l10n.momentsAuthorMe
                        : author.name),
                  ),
              ],
              onChanged: (value) {
                final next = widget.authors.cast<MomentAuthor?>().firstWhere(
                      (author) => author?.id == value,
                      orElse: () => null,
                    );
                if (next != null) setState(() => _author = next);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('moments-compose-body'),
              controller: _controller,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: l10n.momentsComposeHint,
              ),
            ),
            const SizedBox(height: 12),
            if (_imagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_imagePath!),
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('moments-compose-photo'),
                onPressed: _pickPhoto,
                icon: const Icon(Icons.photo_outlined),
                label: Text(
                  _imagePath == null
                      ? l10n.momentsAddPhoto
                      : l10n.momentsChangePhoto,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('moments-compose-send'),
          onPressed: () {
            final body = _controller.text.trim();
            if (body.isEmpty && _imagePath == null) return;
            Navigator.pop(
              context,
              _ComposeDraft(
                author: _author,
                body: body,
                imagePath: _imagePath,
              ),
            );
          },
          child: Text(l10n.send),
        ),
      ],
    );
  }

  Future<void> _pickPhoto() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    setState(() => _imagePath = image.path);
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
            if (post.publicBody.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(post.publicBody),
            ],
            if (post.hasPhoto) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(post.imagePath!),
                  key: Key('moment-photo-${post.id}'),
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ],
            for (final comment in item.comments)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${comment.authorName}: ${comment.body}'),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('moment-comment-${post.id}'),
                onPressed: () => _comment(context, ref, post),
                child: Text(l10n.momentsComment),
              ),
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
