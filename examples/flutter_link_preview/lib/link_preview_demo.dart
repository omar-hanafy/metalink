import 'dart:async';

import 'package:flutter/material.dart';
import 'package:metalink/metalink.dart';
import 'package:metalink_showcase/link_preview_card.dart';

class LinkPreviewDemo extends StatefulWidget {
  const LinkPreviewDemo({super.key});

  @override
  State<LinkPreviewDemo> createState() => _LinkPreviewDemoState();
}

class _LinkPreviewDemoState extends State<LinkPreviewDemo> {
  static const _examples = <String>[
    'https://dart.dev',
    'https://pub.dev',
    'https://github.com',
  ];

  final _urlController = TextEditingController(text: _examples.first);
  final _client = MetaLinkClient(
    options: MetaLinkClientOptions(
      fetch: FetchOptions(
        timeout: const Duration(seconds: 10),
        totalTimeout: const Duration(seconds: 20),
        requestPolicy: RequestPolicy.secure(),
      ),
      extract: const ExtractOptions(maxImages: 3, maxIcons: 3),
      cache: const CacheOptions(enabled: true, ttl: Duration(minutes: 30)),
    ),
  );

  ExtractionResult<LinkMetadata>? _result;
  Completer<void>? _cancellation;
  Object? _unexpectedError;
  bool _loading = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_extract());
  }

  @override
  void dispose() {
    _cancelActiveRequest();
    _urlController.dispose();
    unawaited(_client.dispose());
    super.dispose();
  }

  void _cancelActiveRequest() {
    final cancellation = _cancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Future<void> _extract({bool skipCache = false}) async {
    _cancelActiveRequest();
    final serial = ++_requestSerial;
    final input = _urlController.text.trim();
    final uri = Uri.tryParse(input);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() {
        _result = null;
        _unexpectedError = const FormatException(
          'Enter a complete http or https URL.',
        );
        _loading = false;
      });
      return;
    }

    final cancellation = Completer<void>();
    _cancellation = cancellation;

    setState(() {
      _loading = true;
      _unexpectedError = null;
    });

    try {
      final result = await _client.extract(
        uri.toString(),
        skipCache: skipCache,
        requestContext: RequestContext(cancellationSignal: cancellation.future),
      );
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _result = null;
        _unexpectedError = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colorScheme.primaryContainer.withValues(alpha: 0.55),
              const Color(0xFFF8F6FC),
              colorScheme.tertiaryContainer.withValues(alpha: 0.35),
            ],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 36, 20, 56),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 980),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _ShowcaseHeader(),
                          const SizedBox(height: 28),
                          _buildComposer(context),
                          const SizedBox(height: 22),
                          _buildResult(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x160E0A2B),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => unawaited(_extract()),
            decoration: InputDecoration(
              labelText: 'URL to preview',
              hintText: 'https://example.com',
              prefixIcon: const Icon(Icons.link_rounded),
              suffixIcon: Padding(
                padding: const EdgeInsets.all(6),
                child: FilledButton.icon(
                  onPressed: _loading ? null : () => unawaited(_extract()),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Extract'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Try',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              for (final url in _examples)
                ActionChip(
                  avatar: const Icon(Icons.north_east_rounded, size: 16),
                  label: Text(Uri.parse(url).host),
                  onPressed: () {
                    _urlController.text = url;
                    unawaited(_extract());
                  },
                ),
              if (_result != null)
                ActionChip(
                  avatar: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Refresh'),
                  onPressed: _loading
                      ? null
                      : () => unawaited(_extract(skipCache: true)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    if (_loading) return const LinkPreviewSkeleton();

    final result = _result;
    final metadata = result?.metadataOrNull;
    if (result != null && metadata != null) {
      final provenance =
          result.diagnostics.fieldProvenance[MetaField.title]?.source.name;
      return LinkPreviewCard(
        metadata: metadata,
        status: result.status,
        elapsed: result.diagnostics.totalTime,
        cacheHit: result.diagnostics.cacheHit,
        titleSource: provenance,
      );
    }

    final error = result?.primaryError?.message ?? _unexpectedError?.toString();
    if (error != null) {
      return _ErrorPanel(
        message: error,
        canRetry: result?.retryable ?? true,
        onRetry: () => unawaited(_extract(skipCache: true)),
      );
    }

    return const SizedBox.shrink();
  }
}

class _ShowcaseHeader extends StatelessWidget {
  const _ShowcaseHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              'METALINK ENGINE  >  YOUR FLUTTER UI',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Extract the truth.\nDesign the experience.',
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.02,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'This showcase uses MetaLink directly. The engine owns metadata, '
          'ranking, safety, caching, and diagnostics. The app owns every pixel.',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.message,
    required this.canRetry,
    required this.onRetry,
  });

  final String message;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),
          if (canRetry) ...[
            const SizedBox(width: 12),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}
