import 'package:metalink/src/fetch/fetcher.dart';

/// Capabilities of the default `http` client in browsers.
///
/// The browser client can abort a request but follows redirects itself, so
/// only the final URL is visible. Policies that require inspectable redirects
/// reject this transport before sending a request. When redirects are
/// disabled, the browser rejects a redirect response, which surfaces as a
/// transport error rather than a redirect-limit failure.
FetcherCapabilities defaultHttpFetcherCapabilities() {
  return const FetcherCapabilities(
    supportsAbort: true,
    redirectHandling: RedirectHandlingCapability.unavailable,
    limitation:
        'BrowserClient can follow redirects only as an opaque operation. '
        'Intermediate hops and maxRedirects cannot be inspected or enforced.',
  );
}
