import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class YurichConnectApp extends StatelessWidget {
  const YurichConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0EA5FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Yurich Connect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF06111C),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF06111C),
          foregroundColor: Color(0xFFEAF7FF),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0D1A27),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF10283B),
          hintStyle: const TextStyle(color: Color(0xFF8EA9BD)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF22D3EE)),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
