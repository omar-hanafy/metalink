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

  group('adapts realistic long content to width and text scale', () {
    final longMetadata = LinkMetadata(
      originalUrl: Uri.parse('https://news.example.com/a/1'),
      resolvedUrl: Uri.parse(
        'https://news.example.com/2026/10/11/flutter-accessibility-report',
      ),
      title:
          'An unusually long article title that keeps going so the preview '
          'card has to wrap it across three full lines before truncating it '
          'with an ellipsis at the very end of the third line',
      description:
          'A realistic description that publishers often fill with several '
          'sentences of marketing copy. It is long enough to wrap across four '
          'lines in the wide layout, and it keeps going so the card must clamp '
          'it with an ellipsis instead of letting it push the diagnostics '
          'out of the card bounds on smaller windows.',
      siteName: 'The Extremely Verbose Example Newsroom',
      kind: LinkKind.article,
      images: [
        ImageCandidate(
          url: Uri.parse('https://news.example.com/cover.png'),
          alt: 'Article cover image',
        ),
      ],
      icons: [
        IconCandidate(url: Uri.parse('https://news.example.com/favicon.png')),
      ],
    );

    Future<void> pumpLongCard(
      WidgetTester tester, {
      required double width,
      required double scale,
    }) async {
      tester.view
        ..physicalSize = Size(width, 4000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: LinkPreviewCard(
                metadata: longMetadata,
                status: ExtractionStatus.partial,
                elapsed: const Duration(milliseconds: 1234),
                cacheHit: false,
                titleSource: 'structuredData',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    for (final scale in const [1.0, 1.3, 2.0]) {
      for (final width in const [320.0, 480.0, 720.0, 820.0, 980.0, 1280.0]) {
        testWidgets(
          'has no overflow at ${width.toInt()} px and ${scale}x text',
          (tester) async {
            await pumpLongCard(tester, width: width, scale: scale);

            expect(tester.takeException(), isNull);
            expect(find.text('Partial metadata'), findsOneWidget);
            expect(find.text('Title: structuredData'), findsOneWidget);
            expect(find.text(longMetadata.title!), findsOneWidget);
          },
        );
      }
    }

    final coverImage = find.byWidgetPredicate(
      (widget) =>
          widget is Image && widget.semanticLabel == 'Article cover image',
    );
    final title = find.text(longMetadata.title!);

    // Side by side only while the text column keeps 340 logical px per unit
    // of text scale; otherwise the image stacks above the text.
    for (final (width, scale, sideBySide) in const [
      (720.0, 1.0, true),
      (980.0, 1.3, true),
      (820.0, 1.3, false),
      (980.0, 2.0, false),
      (1280.0, 2.0, true),
    ]) {
      testWidgets(
        '${sideBySide ? 'places the image beside' : 'stacks the image above'} '
        'the text at ${width.toInt()} px and ${scale}x text',
        (tester) async {
          await pumpLongCard(tester, width: width, scale: scale);

          final image = tester.getRect(coverImage);
          final text = tester.getRect(title);
          if (sideBySide) {
            expect(image.right, lessThanOrEqualTo(text.left));
            // The image fills the whole height that the text needs.
            final layout = tester.getRect(
              find
                  .descendant(
                    of: find.byType(LinkPreviewCard),
                    matching: find.byType(Stack),
                  )
                  .first,
            );
            expect(image.top, layout.top);
            expect(image.bottom, layout.bottom);
            expect(text.bottom, lessThan(layout.bottom));
          } else {
            expect(image.bottom, lessThanOrEqualTo(text.top));
          }
        },
      );
    }
  });

  testWidgets('takes its surface colors from the theme', (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6657E8),
        brightness: Brightness.dark,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: LinkPreviewCard(
              metadata: metadata,
              status: ExtractionStatus.success,
              elapsed: const Duration(milliseconds: 8),
              cacheHit: true,
            ),
          ),
        ),
      ),
    );

    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(LinkPreviewCard),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = card.decoration! as BoxDecoration;
    expect(
      decoration.color,
      theme.colorScheme.surfaceContainerLowest.withValues(alpha: 0.92),
    );
  });

  group('LinkPreviewSkeleton', () {
    Future<void> pumpSkeleton(
      WidgetTester tester, {
      required bool disableAnimations,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: disableAnimations),
            child: child!,
          ),
          home: const Scaffold(body: LinkPreviewSkeleton()),
        ),
      );
    }

    testWidgets('pulses and exposes a loading label', (tester) async {
      await pumpSkeleton(tester, disableAnimations: false);

      expect(tester.hasRunningAnimations, isTrue);
      expect(find.bySemanticsLabel('Loading link preview'), findsOneWidget);
    });

    testWidgets('stays still when the platform disables animations', (
      tester,
    ) async {
      await pumpSkeleton(tester, disableAnimations: true);

      expect(tester.hasRunningAnimations, isFalse);
      expect(find.bySemanticsLabel('Loading link preview'), findsOneWidget);
    });
  });
}
