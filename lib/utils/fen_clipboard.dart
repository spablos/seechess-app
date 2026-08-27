import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copy a FEN to the clipboard with a one-line confirmation. Available on
/// every board the app shows — analysis, setup, confirm, match.
Future<void> copyFen(BuildContext context, String fen) async {
  await Clipboard.setData(ClipboardData(text: fen));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('FEN copied\n$fen')));
}

/// Toolbar action shared by all board screens.
class CopyFenButton extends StatelessWidget {
  const CopyFenButton({super.key, required this.fen});
  final String Function() fen;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.content_copy_outlined),
    tooltip: 'Copy FEN',
    onPressed: () => copyFen(context, fen()),
  );
}
