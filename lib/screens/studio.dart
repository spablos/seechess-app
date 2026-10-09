import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/admin.dart';
import '../services/recognizer.dart';
import 'studio_labeler.dart';

/// The admin studio: Pablo's management tools inside the app, unlocked
/// by the admin token. The labeler is native (phone-first); the reels
/// and publish consoles open their responsive web pages with the token.
class StudioScreen extends StatelessWidget {
  const StudioScreen({super.key});

  Future<void> _openConsole(BuildContext context, String path) async {
    final base = await RecognizerClient.savedUrl();
    final token = studioToken.value ?? '';
    final uri = Uri.parse('$base$path?token=$token');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open $uri')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
      bool external = false,
    }) => Card(
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Icon(external ? Icons.open_in_new : Icons.chevron_right),
        onTap: onTap,
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Studio')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          tile(
            icon: Icons.grid_on,
            title: 'Labeler',
            subtitle: 'Correct board readings — one reel style per batch',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StudioLabelerScreen()),
            ),
          ),
          tile(
            icon: Icons.movie_outlined,
            title: 'Reels intake',
            subtitle: 'Fix extracted lines, decide promote/hold/discard',
            external: true,
            onTap: () => _openConsole(context, '/reels'),
          ),
          tile(
            icon: Icons.library_books_outlined,
            title: 'Publish & library',
            subtitle: 'Approve, edit and manage every lesson',
            external: true,
            onTap: () => _openConsole(context, '/lessons/review'),
          ),
          tile(
            icon: Icons.model_training,
            title: 'Training dashboard',
            subtitle: 'Cycles, feedback funnel, model inventory',
            external: true,
            onTap: () => _openConsole(context, '/training'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () async {
              await saveStudioToken(null);
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Lock studio (forget token)'),
          ),
        ],
      ),
    );
  }
}
