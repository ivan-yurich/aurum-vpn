import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class YurichConnectApp extends StatelessWidget {
  const YurichConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFD9A441),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Yurich Connect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0E0B07),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0E0B07),
          foregroundColor: Color(0xFFFFE6A3),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF18130B),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF21180C),
          hintStyle: const TextStyle(color: Color(0xFFB9AA86)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD9A441)),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
