import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'screens/analysis.dart';
import 'screens/home.dart';
import 'screens/offline_lobby.dart';
import 'screens/photo_flow.dart';
import 'utils/position_link.dart';

void main() => runApp(const SeechessApp());

/// Lets the deep-link listener navigate without a BuildContext.
final navigatorKey = GlobalKey<NavigatorState>();

class SeechessApp extends StatefulWidget {
  const SeechessApp({super.key});

  @override
  State<SeechessApp> createState() => _SeechessAppState();
}

class _SeechessAppState extends State<SeechessApp> {
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    // seechess://<ip>:<port> — the offline-match QR scanned with the system
    // camera (in-app scanning bypasses this and parses directly)
    _appLinks.uriLinkStream.listen(_onLink);
    // images shared into the app (screenshot share sheet, WhatsApp "share",
    // "open with") go straight to recognition
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _onSharedMedia(files);
      ReceiveSharingIntent.instance.reset();
    });
    ReceiveSharingIntent.instance.getMediaStream().listen(_onSharedMedia);
  }

  void _onLink(Uri uri) {
    // https://seechess.nopatos.com/p/<fen> — a shared position
    final fen = fenFromLink(uri);
    if (fen != null) {
      _pushWhenReady(
        () => MaterialPageRoute(
          builder: (_) => AnalysisScreen(fen: fen, editable: true),
        ),
      );
      return;
    }
    // seechess://<ip>:<port>[?ssid=&pass=] — the offline-match QR
    if (uri.scheme != 'seechess' || uri.host.isEmpty || !uri.hasPort) return;
    _pushWhenReady(
      () => MaterialPageRoute(
        builder: (_) => JoinMatchScreen(
          address: '${uri.host}:${uri.port}',
          hotspotSsid: uri.queryParameters['ssid'],
          hotspotPass: uri.queryParameters['pass'],
        ),
      ),
    );
  }

  void _onSharedMedia(List<SharedMediaFile> files) {
    final image = files
        .where((f) => f.type == SharedMediaType.image)
        .firstOrNull;
    if (image == null) return;
    _pushWhenReady(
      () => MaterialPageRoute(
        builder: (_) => PhotoFlowScreen(sharedImagePath: image.path),
      ),
    );
  }

  /// On a cold start the shared file / link can arrive before the
  /// navigator exists — wait for the first frame, then push.
  void _pushWhenReady(Route<void> Function() route) {
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.push(route());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => navigatorKey.currentState?.push(route()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seechess',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF739552), // chess.com green
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
