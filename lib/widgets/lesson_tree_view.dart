import 'package:flutter/material.dart';

import '../services/lesson_tree.dart';
import '../services/lessons.dart';

/// The learning-library tree, custom-drawn: vertical rails run through
/// ancestor levels and rounded elbows connect each row to its parent —
/// the ecosystem reads as one connected organism, not an indented list.
class LessonTreeView extends StatelessWidget {
  const LessonTreeView({
    super.key,
    required this.lessons,
    required this.expanded,
    required this.sectionsExpanded,
    required this.onOpenLesson,
    required this.onOpenTrunk,
  });

  final List<Lesson> lessons;
  final bool expanded;
  final bool sectionsExpanded;
  final void Function(Lesson, {int initialPly}) onOpenLesson;
  final void Function(List<String> pathSans, String side) onOpenTrunk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final forest = buildLessonForest(lessons);
    return ListView(
      children: [
        for (final side in const ['w', 'b'])
          ExpansionTile(
            initiallyExpanded: sectionsExpanded,
            shape: const Border(),
            leading: Image.asset(
              side == 'w' ? 'assets/pieces/wK.png' : 'assets/pieces/bK.png',
              width: 26,
              height: 26,
            ),
            title: Text(
              side == 'w' ? 'Playing as White' : 'Playing as Black',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            children: [
              for (final (i, node) in forest[side]!.roots.indexed)
                _NodeTile(
                  node: node,
                  side: side,
                  rails: const [],
                  isLast: i == forest[side]!.roots.length - 1,
                  isRoot: true,
                  expanded: expanded,
                  onOpenLesson: onOpenLesson,
                  onOpenTrunk: onOpenTrunk,
                ),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _NodeTile extends StatefulWidget {
  const _NodeTile({
    required this.node,
    required this.side,
    required this.rails,
    required this.isLast,
    required this.expanded,
    required this.onOpenLesson,
    required this.onOpenTrunk,
    this.isRoot = false,
    this.path = const [],
  });

  final LessonTreeNode node;
  final String side;

  /// One entry per ancestor level: does that ancestor still have siblings
  /// below (draw its vertical rail through this row)?
  final List<bool> rails;
  final bool isLast;
  final bool isRoot;
  final bool expanded;
  final List<String> path;
  final void Function(Lesson, {int initialPly}) onOpenLesson;
  final void Function(List<String> pathSans, String side) onOpenTrunk;

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  late bool _open = widget.expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;
    final fullPath = [...widget.path, ...node.sans];
    final shared = node.lessonCount > 1;
    final name = openingNameFor(fullPath, afterPly: node.startPly);
    final railColor = theme.colorScheme.outlineVariant;

    Widget count(IconData icon, int n, String tip, Color color) => Tooltip(
      message: tip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(
            '$n',
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    // children in connector order: lessons ending here, then sub-branches
    final kids = <Widget>[];
    final total = node.lessonsEndingHere.length + node.children.length;
    var k = 0;
    for (final lesson in node.lessonsEndingHere) {
      kids.add(
        _LeafTile(
          lesson: lesson,
          rails: [...widget.rails, if (!widget.isRoot) !widget.isLast],
          isLast: ++k == total,
          onOpen: widget.onOpenLesson,
        ),
      );
    }
    for (final child in node.children) {
      kids.add(
        _NodeTile(
          node: child,
          side: widget.side,
          rails: [...widget.rails, if (!widget.isRoot) !widget.isLast],
          isLast: ++k == total,
          expanded: widget.expanded,
          path: fullPath,
          onOpenLesson: widget.onOpenLesson,
          onOpenTrunk: widget.onOpenTrunk,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => widget.onOpenTrunk(fullPath, widget.side),
          child: SizedBox(
            height: 46,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 16),
                for (final hasRail in widget.rails)
                  _RailCell(vertical: hasRail, color: railColor),
                if (!widget.isRoot)
                  _RailCell(
                    elbow: true,
                    vertical: !widget.isLast,
                    color: railColor,
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    shared ? Icons.alt_route : Icons.subdirectory_arrow_right,
                    size: 18,
                    color: shared
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name ?? node.shortLabel,
                        overflow: TextOverflow.ellipsis,
                        style: name != null
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 13.5,
                              ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (shared) ...[
                            count(
                              Icons.school,
                              node.lessonCount,
                              'lessons',
                              theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            count(
                              Icons.link,
                              node.endPly,
                              'steps these ${node.lessonCount} lessons share',
                              theme.colorScheme.tertiary,
                            ),
                          ] else
                            count(
                              Icons.straighten,
                              node.endPly,
                              'moves in this line',
                              theme.colorScheme.outline,
                            ),
                          if (name != null) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                node.shortLabel,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontFamily: 'monospace',
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (kids.isNotEmpty)
                  IconButton(
                    icon: Icon(
                      _open
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                    ),
                    onPressed: () => setState(() => _open = !_open),
                  ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        if (_open) ...kids,
      ],
    );
  }
}

class _LeafTile extends StatelessWidget {
  const _LeafTile({
    required this.lesson,
    required this.rails,
    required this.isLast,
    required this.onOpen,
  });

  final Lesson lesson;
  final List<bool> rails;
  final bool isLast;
  final void Function(Lesson, {int initialPly}) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onOpen(lesson),
      child: SizedBox(
        height: 42,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(width: 16),
            for (final hasRail in rails)
              _RailCell(
                vertical: hasRail,
                color: theme.colorScheme.outlineVariant,
              ),
            _RailCell(
              elbow: true,
              vertical: !isLast,
              color: theme.colorScheme.outlineVariant,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.school,
                size: 18,
                color: theme.colorScheme.secondary,
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lesson.title, overflow: TextOverflow.ellipsis),
                  if (lesson.author != null)
                    Text(
                      'by ${lesson.author}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// One rail column: a pass-through vertical line, or an elbow that drops
/// from the top and curves into the node (continuing down when more
/// siblings follow).
class _RailCell extends StatelessWidget {
  const _RailCell({
    this.vertical = false,
    this.elbow = false,
    required this.color,
  });

  final bool vertical;
  final bool elbow;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      child: CustomPaint(
        painter: _RailPainter(vertical: vertical, elbow: elbow, color: color),
        size: const Size(22, double.infinity),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.vertical,
    required this.elbow,
    required this.color,
  });

  final bool vertical;
  final bool elbow;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    final midY = size.height / 2;
    if (elbow) {
      // drop from the top, rounded curve toward the node icon
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x, midY - 6)
        ..quadraticBezierTo(x, midY, x + 6, midY)
        ..lineTo(size.width, midY);
      canvas.drawPath(path, paint);
      if (vertical) {
        canvas.drawLine(Offset(x, midY - 6), Offset(x, size.height), paint);
      }
    } else if (vertical) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RailPainter old) =>
      old.vertical != vertical || old.elbow != elbow || old.color != color;
}
