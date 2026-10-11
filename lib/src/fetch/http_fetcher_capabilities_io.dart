import 'package:metalink/src/fetch/fetcher.dart';

/// Capabilities of the default `http` client on native platforms.
///
/// The `dart:io` client supports aborting a request and honors disabled
/// redirect following, so MetaLink can inspect and validate every hop itself.
FetcherCapabilities defaultHttpFetcherCapabilities() {
  return const FetcherCapabilities(
    supportsAbort: true,
    redirectHandling: RedirectHandlingCapability.inspectable,
  );
}
