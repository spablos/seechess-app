import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'screens/home.dart';
import 'screens/offline_lobby.dart';

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
  }

  void _onLink(Uri uri) {
    if (uri.scheme != 'seechess' || uri.host.isEmpty || !uri.hasPort) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => JoinMatchScreen(address: '${uri.host}:${uri.port}'),
      ),
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
