import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Shareable position links: `https://seechess.nopatos.com/p/FEN`, with the
/// FEN's spaces written as '_'. Opens straight in the app when installed
/// (Universal Link / App Link), otherwise a web page shows the board.
const positionLinkHost = 'seechess.nopatos.com';

String positionLink(String fen) =>
    'https://$positionLinkHost/p/${fen.trim().replaceAll(' ', '_')}';

/// The FEN carried by a position link, or null if [uri] isn't one.
String? fenFromLink(Uri uri) {
  // https://seechess.nopatos.com/p/<slug> (universal/app link) or
  // seechess://p/<slug> (the web page's "Open in Seechess" button)
  final String slug;
  if (uri.host == positionLinkHost && uri.path.startsWith('/p/')) {
    slug = uri.path.substring(3);
  } else if (uri.scheme == 'seechess' && uri.host == 'p') {
    slug = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
  } else {
    return null;
  }
  final fen = Uri.decodeComponent(slug).replaceAll('_', ' ').trim();
  return fen.isEmpty ? null : fen;
}

/// System share sheet with the link (WhatsApp, iMessage, mail…).
Future<void> sharePosition(BuildContext context, String fen) async {
  final link = positionLink(fen);
  await SharePlus.instance.share(
    ShareParams(text: 'Chess position on Seechess: $link'),
  );
}

/// Toolbar action shared by the analysis and confirm screens.
class SharePositionButton extends StatelessWidget {
  const SharePositionButton({super.key, required this.fen});
  final String Function() fen;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.ios_share),
    tooltip: 'Share position',
    onPressed: () => sharePosition(context, fen()),
  );
}
