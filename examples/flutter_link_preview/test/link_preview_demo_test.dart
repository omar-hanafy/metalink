import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metalink/metalink.dart';
import 'package:metalink_showcase/link_preview_demo.dart';

/// Serves canned HTML so the demo runs without network access.
final class _FakeFetcher implements Fetcher {
  _FakeFetcher(this._respond);

  final Future<FetchResponse> Function(Uri url) _respond;

  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) => _respond(url);

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  }) => _respond(url);

  @override
  void close() {}
}

FetchResponse _html(Uri url, String title) {
  return FetchResponse(
    url: url,
    statusCode: 200,
    headers: const {'content-type': 'text/html; charset=utf-8'},
    bodyBytes: utf8.encode(
      '<html><head><title>$title</title>'
      '<meta property="og:title" content="$title">'
      '<meta property="og:site_name" content="Fake site"></head>'
      '<body></body></html>',
    ),
    truncated: false,
    duration: Duration.zero,
  );
}

MetaLinkClient _client(
  WidgetTester tester,
  Future<FetchResponse> Function(Uri url) respond,
) {
  final client = MetaLinkClient(
    fetcher: _FakeFetcher(respond),
    options: const MetaLinkClientOptions(cache: CacheOptions(enabled: false)),
  );
  addTearDown(client.dispose);
  return client;
}

/// Records whether the screen's own default client closed its transport.
///
/// The default `MetaLinkClient` creates a `dart:io` [HttpClient] through
/// [HttpOverrides]; closing that client is the observable end of its lifetime.
final class _RecordingHttpOverrides extends HttpOverrides {
  final clients = <_RecordingHttpClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _RecordingHttpClient();
    clients.add(client);
    return client;
  }
}

final class _RecordingHttpClient implements HttpClient {
  bool closed = false;

  @override
  void close({bool force = false}) => closed = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Future.error(const SocketException('Network disabled in tests.'));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A caller-owned client without a tear-down: a dispose started inside the
/// fake-async test zone never completes there, so these tests dispose it with
/// [WidgetTester.runAsync] once the assertions pass.
MetaLinkClient _callerClient() => MetaLinkClient(
  fetcher: _FakeFetcher((url) async => _html(url, 'Title for ${url.host}')),
  options: const MetaLinkClientOptions(cache: CacheOptions(enabled: false)),
);

Future<String?> _closedMessage(
  WidgetTester tester,
  MetaLinkClient client,
) async {
  final result = await tester.runAsync(
    () => client.extract('https://dart.dev'),
  );
  return result?.primaryError?.message;
}

Future<void> _pumpDemo(WidgetTester tester, MetaLinkClient client) async {
  await tester.pumpWidget(MaterialApp(home: LinkPreviewDemo(client: client)));
  await tester.pump();
}

void main() {
  testWidgets('shows the extracted preview from the injected client', (
    tester,
  ) async {
    final client = _client(
      tester,
      (url) async => _html(url, 'Title for ${url.host}'),
    );

    await _pumpDemo(tester, client);

    expect(find.text('Title for dart.dev'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects an incomplete URL with a readable, final message', (
    tester,
  ) async {
    final client = _client(
      tester,
      (url) async => _html(url, 'Title for ${url.host}'),
    );
    await _pumpDemo(tester, client);

    await tester.enterText(find.byType(TextField), 'dart.dev');
    await tester.tap(find.widgetWithText(FilledButton, 'Extract'));
    await tester.pump();

    expect(find.text('Enter a complete http or https URL.'), findsOneWidget);
    expect(find.textContaining('FormatException'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('ignores a stale response that finishes after a newer one', (
    tester,
  ) async {
    final slowDart = Completer<FetchResponse>();
    final client = _client(tester, (url) {
      if (url.host == 'dart.dev') return slowDart.future;
      return Future.value(_html(url, 'Title for ${url.host}'));
    });
    await _pumpDemo(tester, client);
    expect(find.text('Title for dart.dev'), findsNothing);

    await tester.tap(find.widgetWithText(ActionChip, 'pub.dev'));
    await tester.pump();
    expect(find.text('Title for pub.dev'), findsOneWidget);

    slowDart.complete(
      _html(Uri.parse('https://dart.dev'), 'Title for dart.dev'),
    );
    await tester.pump();

    expect(find.text('Title for pub.dev'), findsOneWidget);
    expect(find.text('Title for dart.dev'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out loading, loaded, and error states at 320 px, 2x text', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final pending = Completer<FetchResponse>();
    final client = _client(tester, (url) {
      if (url.host != 'github.com') return pending.future;
      return Future.value(
        FetchResponse(
          url: url,
          statusCode: 503,
          headers: const {'content-type': 'text/html'},
          bodyBytes: const [],
          truncated: false,
          duration: Duration.zero,
        ),
      );
    });
    await _pumpDemo(tester, client);
    expect(find.bySemanticsLabel('Loading link preview'), findsOneWidget);
    expect(tester.takeException(), isNull);

    pending.complete(
      _html(
        Uri.parse('https://dart.dev'),
        'A long page title that wraps across several lines at large text',
      ),
    );
    await tester.pump();
    expect(find.textContaining('A long page title'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(find.text('Enter a complete http or https URL.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(ActionChip, 'github.com'));
    await tester.pump();
    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'keeps a caller-owned client alive after a rebuild without a client',
    (tester) async {
      final client = _callerClient();
      await _pumpDemo(tester, client);
      expect(find.text('Title for dart.dev'), findsOneWidget);

      // The client is read once, so the screen keeps using the caller's.
      await tester.pumpWidget(const MaterialApp(home: LinkPreviewDemo()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(
        await _closedMessage(tester, client),
        isNot('MetaLinkClient is closed.'),
        reason: 'the screen must not dispose a client it does not own',
      );
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'disposes its own client, not a caller client injected after first build',
    (tester) async {
      final overrides = _RecordingHttpOverrides();
      final previous = HttpOverrides.current;
      HttpOverrides.global = overrides;
      addTearDown(() => HttpOverrides.global = previous);

      await tester.pumpWidget(const MaterialApp(home: LinkPreviewDemo()));
      await tester.pump();
      expect(overrides.clients, hasLength(1));
      final ownTransport = overrides.clients.single;

      final callerClient = _callerClient();
      await tester.pumpWidget(
        MaterialApp(home: LinkPreviewDemo(client: callerClient)),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // Disposal waits for in-flight work before closing the transport.
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !ownTransport.closed; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });

      expect(
        ownTransport.closed,
        isTrue,
        reason: 'the screen must dispose the client it created',
      );
      expect(
        await _closedMessage(tester, callerClient),
        isNot('MetaLinkClient is closed.'),
        reason: 'the screen must not dispose a client it does not own',
      );
      await tester.runAsync(callerClient.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'meets text contrast on the loaded screen, ${brightness.name}',
      (tester) async {
        final client = _client(
          tester,
          (url) async => _html(url, 'Title for ${url.host}'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF6657E8),
                brightness: brightness,
              ),
            ),
            home: LinkPreviewDemo(client: client),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Title for dart.dev'), findsOneWidget);

        await expectLater(tester, meetsGuideline(textContrastGuideline));
      },
    );
  }
}
