import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';

/// Utility functions for HTTP fetching with redirect handling.
///
/// [FetchUtils] provides helper methods for common fetch patterns used
/// throughout the library.
class FetchUtils {
  /// Sends GET requests from [startUrl], following redirects, and returns the
  /// last response.
  ///
  /// Each hop is subject to [FetchOptions.requestPolicy],
  /// [FetchOptions.maxRedirects], and the operation deadline. [purpose]
  /// defaults to [RequestPurpose.enrichment], so sensitive headers are dropped
  /// unless the policy forwards them to enrichments. [maxBytes] caps the body
  /// and defaults to [FetchOptions.maxBytes]. When [context] is `null`, a
  /// context bounded by [FetchOptions.totalTimeout] is used.
  ///
  /// The returned [FetchResponse.url] is the final logical URL. A request
  /// failure is reported in [FetchResponse.error] as a [RequestFailure]
  /// instead of being thrown.
  static Future<FetchResponse> getWithRedirects(
    Fetcher fetcher,
    Uri startUrl, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
    RequestContext? context,
    RequestPurpose purpose = RequestPurpose.enrichment,
  }) async {
    final outcome = await RequestEngine(fetcher: fetcher).execute(
      startUrl,
      options: options,
      context: context ?? RequestContext(totalTimeout: options.totalTimeout),
      purpose: purpose,
      strategy: RequestMethodStrategy.get,
      headers: headers,
      maxBytes: maxBytes,
    );
    return outcome.toFetchResponse();
  }
}
