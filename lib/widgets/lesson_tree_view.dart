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
    this.onRenameNode,
    this.onPreview,
    this.selectedLessonId,
    this.onSelectLeaf,
    this.drillMode = false,
    this.drillSide,
    this.drillPath = const [],
    this.onDrill,
    this.onDrillUp,
  });

  final List<Lesson> lessons;
  final bool expanded;
  final bool sectionsExpanded;
  final void Function(Lesson, {int initialPly}) onOpenLesson;
  final void Function(List<String> pathSans, String side) onOpenTrunk;

  /// Admin mode: rename a node inline — the new name is stored on the
  /// server and reaches every client. null hides the edit affordance.
  final Future<void> Function(List<String> pathSans, String name)? onRenameNode;

  /// Preview board below the tree: called with the moves leading to the
  /// tapped node's end (or a leaf's starting point) and the side.
  final void Function(List<String> sans, String side)? onPreview;

  /// First tap on a leaf previews its starting position (and selects it);
  /// a second tap on the already-selected leaf opens the lesson.
  final String? selectedLessonId;
  final void Function(Lesson lesson, List<String> startSans, String side)?
  onSelectLeaf;

  /// Drill-down mode (file-explorer style): the view shows only the
  /// current subtree — one level of children — with a back row on top.
  final bool drillMode;
  final String? drillSide;
  final List<String> drillPath;
  final void Function(String side, List<String> path)? onDrill;
  final VoidCallback? onDrillUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final forest = buildLessonForest(lessons);
    if (drillMode) return _buildDrill(context, theme, forest);
    return ListView(
      children: [
        for (final side in const ['w', 'b'])
          if (forest[side]!.roots.isNotEmpty)
            ExpansionTile(
              initiallyExpanded: sectionsExpanded,
              shape: const Border(),
              leading: _SideDisc(
                side: side,
                count: forest[side]!.roots.fold(0, (n, r) => n + r.lessonCount),
                size: 34,
              ),
              title: Tooltip(
                message: side == 'w'
                    ? 'Lessons below are from the White playing perspective'
                    : 'Lessons below are from the Black playing perspective',
                child: Text(
                  side == 'w' ? 'White' : 'Black',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
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
                    onRenameNode: onRenameNode,
                    onPreview: onPreview,
                    selectedLessonId: selectedLessonId,
                    onSelectLeaf: onSelectLeaf,
                  ),
              ],
            ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Walk the collapsed tree to the node whose accumulated sans equal
  /// [path]; null means the side's root level.
  LessonTreeNode? _findNode(LessonTree tree, List<String> path) {
    var nodes = tree.roots;
    var i = 0;
    LessonTreeNode? cur;
    while (i < path.length) {
      LessonTreeNode? hit;
      for (final n in nodes) {
        if (i + n.sans.length <= path.length) {
          var ok = true;
          for (var j = 0; j < n.sans.length; j++) {
            if (n.sans[j] != path[i + j]) {
              ok = false;
              break;
            }
          }
          if (ok) {
            hit = n;
            break;
          }
        }
      }
      if (hit == null) return cur;
      cur = hit;
      i += hit.sans.length;
      nodes = hit.children;
    }
    return cur;
  }

  Widget _buildDrill(
    BuildContext context,
    ThemeData theme,
    Map<String, LessonTree> forest,
  ) {
    // top level: the two perspectives act as folders
    if (drillSide == null) {
      return ListView(
        children: [
          for (final side in const ['w', 'b'])
            if (forest[side]!.roots.isNotEmpty)
              _DrillRow(
                disc: _SideDisc(
                  side: side,
                  count: forest[side]!.roots.fold(
                    0,
                    (n, r) => n + r.lessonCount,
                  ),
                  size: 30,
                ),
                title: side == 'w' ? 'White' : 'Black',
                titleStyle: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                onTap: () => onDrill?.call(side, const []),
              ),
          const SizedBox(height: 24),
        ],
      );
    }

    final side = drillSide!;
    final tree = forest[side]!;
    final cur = drillPath.isEmpty ? null : _findNode(tree, drillPath);
    final children = cur?.children ?? tree.roots;
    final ending = cur?.lessonsEndingHere ?? const <Lesson>[];
    final curName = cur == null
        ? (side == 'w' ? 'White' : 'Black')
        : (openingNameFor(drillPath, afterPly: cur.startPly) ?? cur.shortLabel);

    final rows = <Widget>[
      // back row: where you are, tap to go up one level
      InkWell(
        onTap: onDrillUp,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_back,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              _SideDisc(
                side: side,
                count:
                    cur?.lessonCount ??
                    tree.roots.fold(0, (n, r) => n + r.lessonCount),
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  curName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (cur != null)
                IconButton(
                  tooltip: 'Study this line on the board',
                  icon: Icon(
                    Icons.play_circle_outline,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: () => onOpenTrunk(drillPath, side),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
      const Divider(height: 1),
    ];

    for (final lesson in ending) {
      rows.add(
        _LeafTile(
          lesson: lesson,
          rails: const [],
          isLast: true,
          flat: true,
          onOpen: onOpenLesson,
          startSans: drillPath,
          side: side,
          onSelect: onSelectLeaf,
          selected: selectedLessonId == lesson.id,
        ),
      );
    }

    for (final child in children) {
      final childPath = [...drillPath, ...child.sans];
      // a line owned by one lesson is the lesson itself, not a folder
      if (child.lessonCount == 1 &&
          child.children.isEmpty &&
          child.lessonsEndingHere.length == 1) {
        rows.add(
          _LeafTile(
            lesson: child.lessonsEndingHere.first,
            rails: const [],
            isLast: true,
            flat: true,
            moves: child.endPly,
            onOpen: onOpenLesson,
            startSans: drillPath,
            side: side,
            onSelect: onSelectLeaf,
            selected: selectedLessonId == child.lessonsEndingHere.first.id,
          ),
        );
        continue;
      }
      final childName = openingNameFor(childPath, afterPly: child.startPly);
      rows.add(
        _DrillRow(
          disc: _SideDisc(side: side, count: child.lessonCount, size: 26),
          title: childName ?? child.shortLabel,
          titleStyle: childName != null
              ? theme.textTheme.bodyMedium
              : theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 13.5,
                ),
          subtitle: childName != null ? child.shortLabel : null,
          onTap: () {
            onDrill?.call(side, childPath);
            onPreview?.call(childPath, side);
          },
          onOpenBoard: () => onOpenTrunk(childPath, side),
        ),
      );
    }

    rows.add(const SizedBox(height: 24));
    return ListView(children: rows);
  }
}

/// One folder row in drill-down mode: disc, name, optional moves line,
/// explicit board icon, and a chevron hinting "drills deeper".
class _DrillRow extends StatelessWidget {
  const _DrillRow({
    required this.disc,
    required this.title,
    required this.onTap,
    this.titleStyle,
    this.subtitle,
    this.onOpenBoard,
  });

  final Widget disc;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onOpenBoard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 16),
            disc,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            if (onOpenBoard != null)
              IconButton(
                tooltip: 'Study this line on the board',
                icon: Icon(
                  Icons.play_circle_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                onPressed: onOpenBoard,
              ),
            Icon(
              Icons.chevron_right,
              size: 22,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// The side-colored circle used across the whole tree: white disc for
/// White-perspective nodes, black for Black, with the lesson count as a
/// badge on the circle's upper right.
class _SideDisc extends StatelessWidget {
  const _SideDisc({required this.side, required this.count, this.size = 26});

  final String side;
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Badge.count(
      count: count,
      backgroundColor: theme.colorScheme.primary,
      textColor: theme.colorScheme.onPrimary,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: side == 'w' ? Colors.white : const Color(0xFF1E1E1E),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Icon(
          Icons.school,
          size: size * 0.55,
          color: side == 'w' ? Colors.black54 : Colors.white70,
        ),
      ),
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
    this.onRenameNode,
    this.onPreview,
    this.selectedLessonId,
    this.onSelectLeaf,
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
  final Future<void> Function(List<String> pathSans, String name)? onRenameNode;
  final void Function(List<String> sans, String side)? onPreview;
  final String? selectedLessonId;
  final void Function(Lesson lesson, List<String> startSans, String side)?
  onSelectLeaf;

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile> {
  late bool _open = widget.expanded;

  /// Inline rename (admin): the name text swaps to a text field.
  bool _editing = false;
  final TextEditingController _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitRename(List<String> fullPath) async {
    final name = _nameCtrl.text.trim();
    setState(() => _editing = false);
    await widget.onRenameNode?.call(fullPath, name);
  }

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

    // a line owned by exactly one lesson renders as ONE row — a trunk row
    // plus a leaf repeating the same name read as duplication (Pablo)
    if (!shared &&
        node.children.isEmpty &&
        node.lessonsEndingHere.length == 1) {
      return _LeafTile(
        lesson: node.lessonsEndingHere.first,
        rails: widget.rails,
        isLast: widget.isLast,
        moves: node.endPly,
        onOpen: widget.onOpenLesson,
        startSans: widget.path,
        side: widget.side,
        onSelect: widget.onSelectLeaf,
        selected: widget.selectedLessonId == node.lessonsEndingHere.first.id,
      );
    }

    // children in connector order: lessons ending here, then sub-branches
    final kids = <Widget>[];
    final total = node.lessonsEndingHere.length + node.children.length;
    var k = 0;
    for (final lesson in node.lessonsEndingHere) {
      kids.add(
        _LeafTile(
          lesson: lesson,
          rails: [...widget.rails, !widget.isLast],
          isLast: ++k == total,
          onOpen: widget.onOpenLesson,
          startSans: widget.path,
          side: widget.side,
          onSelect: widget.onSelectLeaf,
          selected: widget.selectedLessonId == lesson.id,
        ),
      );
    }
    for (final child in node.children) {
      kids.add(
        _NodeTile(
          node: child,
          side: widget.side,
          rails: [...widget.rails, !widget.isLast],
          isLast: ++k == total,
          expanded: widget.expanded,
          path: fullPath,
          onOpenLesson: widget.onOpenLesson,
          onOpenTrunk: widget.onOpenTrunk,
          onRenameNode: widget.onRenameNode,
          onPreview: widget.onPreview,
          selectedLessonId: widget.selectedLessonId,
          onSelectLeaf: widget.onSelectLeaf,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          // a branch row is a container, not a lesson: every part of it —
          // hats, digit, title — expands/collapses; only leaf titles open
          // the board (Pablo). Long-press still replays the shared line.
          onTap: () {
            setState(() => _open = !_open);
            widget.onPreview?.call(fullPath, widget.side);
          },
          onLongPress: () => widget.onOpenTrunk(fullPath, widget.side),
          child: SizedBox(
            height: 46,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 56),
                for (final hasRail in widget.rails)
                  _RailCell(vertical: hasRail, color: railColor),
                _RailCell(
                  elbow: true,
                  vertical: !widget.isLast,
                  color: railColor,
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Center(
                    child: Tooltip(
                      message:
                          '${node.lessonCount} lesson${node.lessonCount == 1 ? '' : 's'} under this line',
                      child: _SideDisc(
                        side: widget.side,
                        count: node.lessonCount,
                        size: 26,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_editing)
                        SizedBox(
                          height: 24,
                          child: TextField(
                            controller: _nameCtrl,
                            autofocus: true,
                            style: theme.textTheme.bodyMedium,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'Node name (empty = show moves)',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                            ),
                            onSubmitted: (_) => _submitRename(fullPath),
                            onTapOutside: (_) =>
                                setState(() => _editing = false),
                          ),
                        )
                      else
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name ?? node.shortLabel,
                                overflow: TextOverflow.ellipsis,
                                style: name != null
                                    ? theme.textTheme.bodyMedium
                                    : theme.textTheme.bodyMedium?.copyWith(
                                        fontFamily: 'monospace',
                                        fontSize: 13.5,
                                      ),
                              ),
                            ),
                            if (widget.onRenameNode != null) ...[
                              const SizedBox(width: 6),
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => setState(() {
                                  _nameCtrl.text = name ?? '';
                                  _editing = true;
                                }),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 14,
                                    color: theme.colorScheme.outline,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (shared)
                            // the chain is the row's board affordance:
                            // tapping it replays the shared steps, while
                            // the rest of the row expands/collapses
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () =>
                                  widget.onOpenTrunk(fullPath, widget.side),
                              child: count(
                                Icons.link,
                                node.endPly,
                                'steps these ${node.lessonCount} lessons '
                                'share — tap to replay them on the board',
                                theme.colorScheme.tertiary,
                              ),
                            )
                          else
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
                IconButton(
                  tooltip: 'Study this line on the board',
                  icon: Icon(
                    Icons.play_circle_outline,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: () => widget.onOpenTrunk(fullPath, widget.side),
                ),
                if (kids.isNotEmpty)
                  IconButton(
                    icon: AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        Icons.expand_circle_down_outlined,
                        size: 20,
                        color: theme.colorScheme.outline,
                      ),
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
    this.moves,
    this.startSans = const [],
    this.side = 'w',
    this.onSelect,
    this.selected = false,
    this.flat = false,
  });

  final Lesson lesson;
  final List<bool> rails;
  final bool isLast;
  final int? moves;
  final void Function(Lesson, {int initialPly}) onOpen;

  /// Moves leading to where this lesson's own line begins — shown on the
  /// preview board on first tap; the second tap opens the lesson.
  final List<String> startSans;
  final String side;
  final void Function(Lesson lesson, List<String> startSans, String side)?
  onSelect;
  final bool selected;

  /// Drill-down mode: no rails/elbow, flush-left like a file row.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      // browse-then-enter: first tap previews the leaf's starting
      // position on the board below; tapping the selected leaf opens it
      // the row only selects/previews; the play icon opens the lesson
      // (with no preview context the row opens directly)
      onTap: () {
        if (onSelect == null) {
          onOpen(lesson);
        } else {
          onSelect!(lesson, startSans, side);
        }
      },
      child: Container(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
            : null,
        height: 42,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (flat)
              const SizedBox(width: 16)
            else ...[
              const SizedBox(width: 56),
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
            ],
            // same disc as branch rows (count 1) — one visual system
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(child: _SideDisc(side: side, count: 1, size: 26)),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lesson.title, overflow: TextOverflow.ellipsis),
                  Row(
                    children: [
                      if (moves != null) ...[
                        Icon(
                          Icons.straighten,
                          size: 12,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$moves',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (moves != null && lesson.author != null)
                        const SizedBox(width: 10),
                      if (lesson.author != null)
                        Flexible(
                          child: Text(
                            'by ${lesson.author}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Center(
              child: IconButton(
                tooltip: 'Open this lesson',
                icon: Icon(
                  Icons.play_circle_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                onPressed: () => onOpen(lesson),
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
