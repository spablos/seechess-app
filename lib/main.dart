import 'package:flutter/material.dart';

import 'screens/home.dart';

void main() => runApp(const SeechessApp());

class SeechessApp extends StatelessWidget {
  const SeechessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seechess',
      debugShowCheckedModeBanner: false,
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
