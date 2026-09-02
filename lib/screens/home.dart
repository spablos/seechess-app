import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'analysis.dart';
import 'offline_lobby.dart';
import 'photo_flow.dart';
import 'learn.dart';
import 'saved_games.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/branding/seechess-logo.jpg',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _ActionCard(
                    icon: Icons.photo_camera,
                    color: theme.colorScheme.primary,
                    title: 'Analyze a photo',
                    subtitle:
                        'Snap a real board or a screenshot — get the position '
                        'on a live Stockfish board',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PhotoFlowScreen(),
                      ),
                    ),
                  ),
                  _ActionCard(
                    icon: Icons.query_stats,
                    color: const Color(0xFF6A9BD8),
                    title: 'Analysis board',
                    subtitle:
                        'Start from the initial position and explore with the '
                        'engine',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AnalysisScreen(editable: true),
                      ),
                    ),
                  ),
                  _ActionCard(
                    icon: Icons.school,
                    color: const Color(0xFFD9822B),
                    title: 'Learn',
                    subtitle:
                        'Classic openings and traps, explained move by move',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LearnScreen()),
                    ),
                  ),
                  _ActionCard(
                    icon: Icons.bookmark,
                    color: const Color(0xFF9C7BC9),
                    title: 'Library',
                    subtitle:
                        'Every confirmed board and saved game — search, '
                        'labels, history',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SavedGamesScreen(),
                      ),
                    ),
                  ),
                  // Play offline is a different kind of thing (a match, not
                  // recognition/analysis) — set apart below a divider
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Divider(),
                  ),
                  _ActionCard(
                    icon: Icons.wifi_tethering,
                    color: const Color(0xFFC98F3B),
                    title: 'Play offline',
                    subtitle:
                        'Two phones, no internet — a real match with clocks',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OfflineLobbyScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // which build is running — first thing support asks for
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  snap.hasData
                      ? 'Seechess ${snap.data!.version} '
                            '(${snap.data!.buildNumber})'
                      : '',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: enabled ? 2 : 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (enabled)
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
