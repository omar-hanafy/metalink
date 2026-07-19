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
