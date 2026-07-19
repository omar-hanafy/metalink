import 'package:metalink/src/fetch/fetcher.dart';

FetcherCapabilities defaultHttpFetcherCapabilities() {
  return const FetcherCapabilities(
    supportsAbort: true,
    redirectHandling: RedirectHandlingCapability.inspectable,
  );
}
