import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'package:native_tavern/presentation/router/app_router.dart';

/// Play tab hub: four names only. No timeline, switches, or status.
class PlayHubScreen extends StatelessWidget {
  const PlayHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.playHub)),
      body: ListView(
        children: [
          _PlayHubRow(
            key: const Key('play-hub-moments'),
            icon: Icons.dynamic_feed_outlined,
            title: l10n.moments,
            onTap: () => context.push(AppRoutes.playMoments),
          ),
          _PlayHubRow(
            key: const Key('play-hub-story'),
            icon: Icons.menu_book_outlined,
            title: l10n.story,
            onTap: () => context.push(AppRoutes.playStory),
          ),
          _PlayHubRow(
            key: const Key('play-hub-world-info'),
            icon: Icons.public_outlined,
            title: l10n.worldInfo,
            onTap: () => context.push(AppRoutes.worldInfo),
          ),
          _PlayHubRow(
            key: const Key('play-hub-data-bank'),
            icon: Icons.library_books_outlined,
            title: l10n.dataBank,
            onTap: () => context.push(AppRoutes.dataBank),
          ),
        ],
      ),
    );
  }
}

class _PlayHubRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _PlayHubRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
