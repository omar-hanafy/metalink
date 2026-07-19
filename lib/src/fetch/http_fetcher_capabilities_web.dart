import 'package:metalink/src/fetch/fetcher.dart';

FetcherCapabilities defaultHttpFetcherCapabilities() {
  return const FetcherCapabilities(
    supportsAbort: true,
    redirectHandling: RedirectHandlingCapability.unavailable,
    limitation:
        'BrowserClient can follow redirects only as an opaque operation. '
        'Intermediate hops and maxRedirects cannot be inspected or enforced.',
  );
}
