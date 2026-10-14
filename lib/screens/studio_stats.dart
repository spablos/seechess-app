import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/lessons.dart';
import '../services/recognizer.dart';
import '../services/stats_admin.dart';

/// Native usage analytics inside the Studio — the /stats numbers without
/// leaving the app. Anonymous device footprints only (random install
/// ids), same data the web page and the Excel export show.
class StudioStatsScreen extends StatefulWidget {
  const StudioStatsScreen({super.key});

  @override
  State<StudioStatsScreen> createState() => _StudioStatsScreenState();
}

class _StudioStatsScreenState extends State<StudioStatsScreen> {
  StatsSummary? _s;
  bool _loading = true;
  int _days = 30;
  int? _picked; // tapped bar index

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await fetchStatsSummary(days: _days);
    if (!mounted) return;
    setState(() {
      _s = s;
      _loading = false;
      _picked = null;
    });
  }

  Future<void> _openWeb(String path) async {
    final base = await RecognizerClient.savedUrl();
    final token = adminToken() ?? '';
    await launchUrl(
      Uri.parse('$base$path?token=$token&days=$_days'),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _s;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage stats'),
        actions: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 30, label: Text('30d')),
              ButtonSegment(value: 60, label: Text('60d')),
              ButtonSegment(value: 90, label: Text('90d')),
            ],
            selected: {_days},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (v) {
              _days = v.first;
              _load();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : s == null
          ? Center(
              child: TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Could not load — retry'),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _kpiGrid(theme, s),
                  const SizedBox(height: 16),
                  Text(
                    'Daily active devices',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _dailyChart(theme, s),
                  const SizedBox(height: 16),
                  Text('Last 14 days', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  _dailyTable(theme, s),
                  const SizedBox(height: 16),
                  _breakdown(theme, 'Platforms (active 7d)', s.platforms),
                  _breakdown(theme, 'Versions (active 7d)', s.versions, top: 6),
                  _breakdown(
                    theme,
                    'Countries (active 7d)',
                    s.countries,
                    top: 8,
                  ),
                  _breakdown(
                    theme,
                    'Feature use (${_days}d totals)',
                    s.features,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openWeb('/stats'),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: const Text('Web version'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openWeb('/stats.xlsx'),
                          icon: const Icon(Icons.table_view, size: 18),
                          label: const Text('Excel'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _kpi(ThemeData theme, String value, String label) => Expanded(
    child: Card(
      margin: const EdgeInsets.all(3),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Column(
          children: [
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _kpiGrid(ThemeData theme, StatsSummary s) => Column(
    children: [
      Row(
        children: [
          _kpi(theme, '${s.dau}', 'active today'),
          _kpi(theme, '${s.wau}', '7-day actives'),
          _kpi(theme, '${s.mau}', '30-day actives'),
        ],
      ),
      Row(
        children: [
          _kpi(theme, '${s.installs}', 'installs ever'),
          _kpi(theme, s.retentionD1, 'day-1 retention'),
          _kpi(theme, s.retentionD7, 'day-7 retention'),
        ],
      ),
    ],
  );

  Widget _dailyChart(ThemeData theme, StatsSummary s) {
    final days = s.daily;
    final picked = _picked;
    final caption = picked != null && picked < days.length
        ? '${days[picked].date} — ${days[picked].active} active, '
              '${days[picked].scans} scans'
        : 'tap a bar for the day\'s numbers';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 140,
          child: GestureDetector(
            onTapDown: (d) {
              final w = context.size?.width ?? 300;
              final i = (d.localPosition.dx / (w - 24) * days.length)
                  .floor()
                  .clamp(0, days.length - 1);
              setState(() => _picked = i);
            },
            child: CustomPaint(
              painter: _BarsPainter(
                values: [for (final d in days) d.active],
                picked: picked,
                bar: theme.colorScheme.primary,
                pickedBar: theme.colorScheme.tertiary,
                grid: theme.colorScheme.outlineVariant,
                ink: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              days.isEmpty ? '' : days.first.date.substring(5),
              style: theme.textTheme.labelSmall,
            ),
            Text(caption, style: theme.textTheme.labelSmall),
            Text(
              days.isEmpty ? '' : days.last.date.substring(5),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _dailyTable(ThemeData theme, StatsSummary s) {
    final recent = s.daily.reversed.take(14).toList();
    final num14 = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget cell(String t, {bool head = false, int flex = 2}) => Expanded(
      flex: flex,
      child: Text(
        t,
        textAlign: TextAlign.right,
        style: head
            ? theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )
            : num14,
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Text('date', style: theme.textTheme.labelSmall),
            ),
            cell('active', head: true),
            cell('new', head: true),
            cell('scans', head: true),
            cell('feedback', head: true, flex: 3),
          ],
        ),
        const Divider(height: 8),
        for (final d in recent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(d.date.substring(5), style: num14),
                ),
                cell('${d.active}'),
                cell('${d.fresh}'),
                cell('${d.scans}'),
                cell('${d.feedback}', flex: 3),
              ],
            ),
          ),
      ],
    );
  }

  Widget _breakdown(
    ThemeData theme,
    String title,
    Map<String, int> data, {
    int top = 10,
  }) {
    final items = data.entries.take(top).toList();
    final maxV = items.isEmpty
        ? 1
        : items.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final num13 = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          if (items.isEmpty)
            Text('—', style: theme.textTheme.bodySmall)
          else
            for (final e in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        e.key,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: e.value / maxV,
                          minHeight: 8,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${e.value}',
                        textAlign: TextAlign.right,
                        style: num13,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// Thin bars, 4px-rounded tops anchored to the baseline, recessive grid.
class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.picked,
    required this.bar,
    required this.pickedBar,
    required this.grid,
    required this.ink,
  });

  final List<int> values;
  final int? picked;
  final Color bar;
  final Color pickedBar;
  final Color grid;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // two recessive gridlines: midpoint and top (labeled max)
    for (final f in [0.5, 1.0]) {
      final y = size.height - 14 - (size.height - 20) * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '$maxV',
        style: TextStyle(fontSize: 9, color: ink),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(0, 0));

    final n = values.length;
    final slot = size.width / n;
    final barW = (slot * 0.7).clamp(1.0, 14.0);
    final base = size.height - 14;
    for (var i = 0; i < n; i++) {
      final h = (size.height - 20) * values[i] / maxV;
      if (h <= 0) continue;
      final r = RRect.fromRectAndCorners(
        Rect.fromLTWH(i * slot + (slot - barW) / 2, base - h, barW, h),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(r, Paint()..color = i == picked ? pickedBar : bar);
    }
    canvas.drawLine(
      Offset(0, base),
      Offset(size.width, base),
      gridPaint..color = grid,
    );
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.values != values || old.picked != picked || old.bar != bar;
}
