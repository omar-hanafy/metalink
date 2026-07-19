import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metalink/metalink.dart';
import 'package:metalink_showcase/link_preview_card.dart';

void main() {
  final metadata = LinkMetadata(
    originalUrl: Uri.parse('https://dart.dev/guides'),
    resolvedUrl: Uri.parse('https://dart.dev/guides'),
    title: 'Dart documentation',
    description: 'Language guides, libraries, and tools for Dart developers.',
    siteName: 'Dart',
    kind: LinkKind.article,
  );

  testWidgets('renders a custom preview without package-owned UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: LinkPreviewCard(
                  metadata: metadata,
                  status: ExtractionStatus.success,
                  elapsed: Duration(milliseconds: 42),
                  cacheHit: false,
                  titleSource: 'openGraph',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Dart documentation'), findsOneWidget);
    expect(find.text('Dart'), findsOneWidget);
    expect(find.text('dart.dev'), findsOneWidget);
    expect(find.text('Complete metadata'), findsOneWidget);
    expect(find.text('Fetched live'), findsOneWidget);
    expect(find.text('42 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows partial status on a wide layout without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 900,
              child: LinkPreviewCard(
                metadata: metadata,
                status: ExtractionStatus.partial,
                elapsed: Duration(milliseconds: 8),
                cacheHit: true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Partial metadata'), findsOneWidget);
    expect(find.text('Cache hit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
