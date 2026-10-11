import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';

/// Resolves URL redirects to discover the final destination.
///
/// [RedirectResolver] follows HTTP redirects (301, 302, 303, 307, 308) using
/// HEAD requests to avoid downloading response bodies. Falls back to GET
/// when HEAD is not supported.
///
/// ### When to Use
/// Use via `MetaLinkClient.optimizeUrl` to resolve shortened URLs (bit.ly,
/// t.co) or discover canonical destinations without full metadata extraction.
///
/// ### Example
/// ```dart
/// final resolver = RedirectResolver(fetcher: HttpFetcher());
/// final result = await resolver.resolve(
///   Uri.parse('https://bit.ly/example'),
///   options: FetchOptions(),
/// );
/// print('Final URL: ${result.finalUrl}');
/// print('Redirects: ${result.redirects.length}');
/// ```
class RedirectResolver {
  /// Creates a [RedirectResolver] with the given [Fetcher].
  RedirectResolver({required this._fetcher});

  final Fetcher _fetcher;

  /// Follows redirects from [url] and reports the final destination.
  ///
  /// Each hop sends HEAD and falls back to a GET that reads no body when HEAD
  /// fails or returns `405` or `501`. Every hop is subject to
  /// [FetchOptions.requestPolicy], [FetchOptions.maxRedirects], and the
  /// operation deadline. When [context] is `null`, a context bounded by
  /// [FetchOptions.totalTimeout] is used.
  ///
  /// This method does not throw. A request failure is reported in
  /// [UrlOptimizationResult.error], usually as a [RequestFailure], together
  /// with the last URL reached.
  Future<UrlOptimizationResult> resolve(
    Uri url, {
    required FetchOptions options,
    RequestContext? context,
  }) async {
    try {
      final outcome = await RequestEngine(fetcher: _fetcher).execute(
        url,
        options: options,
        context: context ?? RequestContext(totalTimeout: options.totalTimeout),
        purpose: RequestPurpose.redirectResolution,
        strategy: RequestMethodStrategy.headWithGetFallback,
        maxBytes: 0,
      );
      return UrlOptimizationResult(
        originalUrl: outcome.originalUrl,
        finalUrl: outcome.finalUrl,
        redirects: outcome.redirects,
        statusCode: outcome.response?.statusCode,
        duration: outcome.duration,
        error: outcome.failure ?? outcome.response?.error,
        stackTrace: outcome.failure?.stackTrace ?? outcome.response?.stackTrace,
      );
    } catch (e, st) {
      return UrlOptimizationResult(
        originalUrl: url,
        finalUrl: url,
        redirects: const <RedirectHop>[],
        statusCode: null,
        duration: Duration.zero,
        error: e,
        stackTrace: st,
      );
    }
  }
}
