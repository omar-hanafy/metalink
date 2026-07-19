import 'package:flutter/material.dart';
import 'package:metalink_showcase/link_preview_demo.dart';

void main() {
  runApp(const MetaLinkShowcaseApp());
}

class MetaLinkShowcaseApp extends StatelessWidget {
  const MetaLinkShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6657E8);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MetaLink Flutter showcase',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF8F6FC),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.88),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const LinkPreviewDemo(),
    );
  }
}
