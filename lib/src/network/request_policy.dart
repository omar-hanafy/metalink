import 'dart:async';

import 'package:metalink/src/network/request_target_safety.dart';

/// Identifies why MetaLink is performing a network request.
enum RequestPurpose {
  /// Fetching the primary HTML document.
  document,

  /// Resolving a URL without extracting its document.
  redirectResolution,

  /// Fetching an oEmbed endpoint discovered in HTML.
  oEmbed,

  /// Fetching a web app manifest discovered in HTML.
  manifest,

  /// Another explicitly requested enrichment resource.
  enrichment,
}

/// Identifies where a target entered a logical request.
enum RequestTargetStage {
  /// The initial caller-supplied target.
  initial,

  /// A target supplied by an HTTP `Location` response header.
  redirect,

  /// The actual proxy endpoint after target transformation.
  proxy,
}

/// Context supplied to request target policy validators.
class RequestTarget {
  /// Creates target validation context.
  const RequestTarget({
    required this.uri,
    required this.purpose,
    required this.stage,
    required this.redirectCount,
    this.previousUri,
  });

  /// The logical or proxy URI being validated.
  final Uri uri;

  /// The reason for the network request.
  final RequestPurpose purpose;

  /// How this target entered the request.
  final RequestTargetStage stage;

  /// Number of redirect hops already accepted.
  final int redirectCount;

  /// The previous logical target for redirect validation.
  final Uri? previousUri;
}

/// Result returned by a [RequestTargetValidator].
class RequestPolicyDecision {
  const RequestPolicyDecision._({required this.allowed, this.reason});

  /// Allows the target.
  const RequestPolicyDecision.allow() : this._(allowed: true);

  /// Rejects the target with a human-readable [reason].
  const RequestPolicyDecision.reject(String reason)
    : this._(allowed: false, reason: reason);

  /// Whether the target may be requested.
  final bool allowed;

  /// Why the target was rejected.
  final String? reason;
}

/// Validates one logical or proxy request target.
typedef RequestTargetValidator =
    FutureOr<RequestPolicyDecision> Function(RequestTarget target);

/// Security and trust-boundary rules for [RequestEngine].
///
/// The default constructor preserves MetaLink 2.x target compatibility by
/// allowing all valid HTTP(S) hosts. Sensitive headers are still removed when
/// a redirect changes origin. Use [RequestPolicy.secure] for untrusted input.
class RequestPolicy {
  /// Creates request policy controls.
  const RequestPolicy({
    this.targetValidator,
    this.proxyTargetValidator,
    this.cachePartition = 'compatible',
    this.stripSensitiveHeadersOnCrossOriginRedirect = true,
    this.forwardSensitiveHeadersToEnrichments = false,
    this.forwardSensitiveHeadersThroughProxy = true,
    this.requireInspectableRedirects = false,
    this.sensitiveHeaders = _defaultSensitiveHeaders,
  }) : assert(cachePartition != '');

  /// Creates a stricter preset for processing untrusted URLs.
  ///
  /// This blocks common local, private-literal, link-local, multicast, and
  /// metadata-service targets, requires inspectable redirect hops, prevents
  /// sensitive headers from traversing a URL-rewrite proxy, and composes an
  /// optional [additionalValidator]. Hostname-to-address validation and DNS
  /// pinning still belong in a policy-aware platform transport.
  factory RequestPolicy.secure({
    RequestTargetValidator? additionalValidator,
    RequestTargetValidator? proxyTargetValidator,
    String cachePartition = 'secure',
  }) {
    return RequestPolicy(
      targetValidator: (target) async {
        final unsafeReason = unsafeTargetReason(target.uri);
        if (unsafeReason != null) {
          return RequestPolicyDecision.reject(unsafeReason);
        }
        if (additionalValidator == null) {
          return const RequestPolicyDecision.allow();
        }
        return additionalValidator(target);
      },
      proxyTargetValidator: proxyTargetValidator,
      cachePartition: cachePartition,
      forwardSensitiveHeadersThroughProxy: false,
      requireInspectableRedirects: true,
    );
  }

  static const Set<String> _defaultSensitiveHeaders = <String>{
    'authorization',
    'cookie',
    'cookie2',
    'proxy-authorization',
    'x-api-key',
  };

  /// Optional validator applied to every initial and redirect target.
  final RequestTargetValidator? targetValidator;

  /// Optional validator applied to the transformed proxy endpoint.
  final RequestTargetValidator? proxyTargetValidator;

  /// Stable cache identity for requests governed by this policy.
  ///
  /// Callers supplying custom validators should also supply a unique partition
  /// whenever those validators can change which targets or redirects are valid.
  final String cachePartition;

  /// Whether sensitive headers are removed when redirect origin changes.
  final bool stripSensitiveHeadersOnCrossOriginRedirect;

  /// Whether document credentials may be sent to discovered enrichment URLs.
  final bool forwardSensitiveHeadersToEnrichments;

  /// Whether sensitive target headers may be sent through a rewrite proxy.
  final bool forwardSensitiveHeadersThroughProxy;

  /// Whether a transport with hidden redirect behavior must be rejected.
  final bool requireInspectableRedirects;

  /// Case-insensitive header names treated as credentials or secrets.
  final Set<String> sensitiveHeaders;

  /// Stable identity for caches governed by this policy configuration.
  ///
  /// Custom validator behavior cannot be introspected, so callers using one
  /// must provide a unique [cachePartition] when its admission rules differ.
  String get cacheIdentity {
    final normalizedHeaders =
        sensitiveHeaders.map((header) => header.toLowerCase()).toSet().toList()
          ..sort();
    return <String>[
      cachePartition,
      'crossOrigin=$stripSensitiveHeadersOnCrossOriginRedirect',
      'enrichments=$forwardSensitiveHeadersToEnrichments',
      'proxy=$forwardSensitiveHeadersThroughProxy',
      'inspectable=$requireInspectableRedirects',
      'sensitive=${normalizedHeaders.join(',')}',
    ].join('|');
  }

  /// Validates an initial or redirect [target].
  Future<RequestPolicyDecision> validateTarget(RequestTarget target) async {
    final validator = targetValidator;
    if (validator == null) return const RequestPolicyDecision.allow();
    return validator(target);
  }

  /// Validates a transformed proxy [target].
  Future<RequestPolicyDecision> validateProxyTarget(
    RequestTarget target,
  ) async {
    final validator = proxyTargetValidator;
    if (validator == null) return const RequestPolicyDecision.allow();
    return validator(target);
  }

  /// Returns headers safe for the initial request [purpose].
  Map<String, String> headersForInitial(
    RequestPurpose purpose,
    Map<String, String> headers,
  ) {
    final isEnrichment =
        purpose == RequestPurpose.oEmbed ||
        purpose == RequestPurpose.manifest ||
        purpose == RequestPurpose.enrichment;
    if (!isEnrichment || forwardSensitiveHeadersToEnrichments) {
      return headers;
    }
    return _withoutSensitiveHeaders(headers);
  }

  /// Returns headers safe to use after redirecting from [from] to [to].
  Map<String, String> headersForRedirect(
    Uri from,
    Uri to,
    Map<String, String> headers,
  ) {
    if (!stripSensitiveHeadersOnCrossOriginRedirect ||
        _isSameOrigin(from, to)) {
      return headers;
    }
    return _withoutSensitiveHeaders(headers);
  }

  /// Returns headers safe to send to a URL-rewrite proxy.
  Map<String, String> headersForProxy(Map<String, String> headers) {
    return forwardSensitiveHeadersThroughProxy
        ? headers
        : _withoutSensitiveHeaders(headers);
  }

  Map<String, String> _withoutSensitiveHeaders(Map<String, String> headers) {
    final normalizedSensitive = sensitiveHeaders
        .map((name) => name.toLowerCase())
        .toSet();
    return <String, String>{
      for (final entry in headers.entries)
        if (!normalizedSensitive.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  static bool _isSameOrigin(Uri a, Uri b) {
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        _effectivePort(a) == _effectivePort(b);
  }

  static int _effectivePort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme.toLowerCase() == 'http' ? 80 : 443;
  }
}
