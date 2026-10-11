import 'dart:async';

import 'package:metalink/src/extract/url_resolver.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/network/deadline_timer.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/url_normalizer.dart';

/// The HTTP method strategy used for one logical request.
enum RequestMethodStrategy {
  /// Use GET for every hop.
  get,

  /// Use HEAD for every hop.
  head,

  /// Prefer HEAD, falling back to a zero-byte GET for unsupported HEAD.
  headWithGetFallback,

  /// Resolve with HEAD, then use GET for the document and later hops.
  headThenGet,
}

/// Stable categories for failures enforced by [RequestEngine].
enum RequestFailureCode {
  /// The initial target is not an absolute HTTP(S) URL with a host.
  invalidTarget,

  /// The request policy rejected an initial, redirect, or proxy target.
  ///
  /// A validator that throws also fails closed with this code, and the thrown
  /// error is kept in [RequestFailure.cause].
  policyRejected,

  /// [FetchOptions.proxyUrl] could not be applied to the target.
  proxyConfiguration,

  /// A redirect arrived after [FetchOptions.maxRedirects] hops were used.
  ///
  /// With a `maxRedirects` of `0`, the first redirect fails with this code.
  /// A browser transport cannot expose redirects, so on the web a redirect
  /// with redirects disabled is reported as [transport] instead.
  redirectLimit,

  /// A redirect led back to a URL already requested by this operation.
  redirectLoop,

  /// A redirect `Location` is not a valid HTTP(S) URL, or an opaque transport
  /// reported an invalid final URL.
  invalidRedirect,

  /// The complete-operation deadline elapsed, or one attempt exceeded
  /// [FetchOptions.timeout].
  timeout,

  /// The caller cancelled through [RequestContext.cancellationSignal], or the
  /// transport reported a [FetchCancellationException].
  cancelled,

  /// The [Fetcher] reported any other error.
  transport,

  /// The policy requires inspectable redirects, but the [Fetcher] cannot
  /// guarantee them.
  ///
  /// See [RequestPolicy.requireInspectableRedirects]. A fetcher whose declared
  /// capabilities rule out inspection fails before any request is sent. A
  /// fetcher assumed or declared to be inspectable fails after a response
  /// reports a URL other than the one requested, which shows that it followed
  /// a redirect without per-hop validation; that response is discarded.
  unsupportedCapability,
}

/// A typed failure from the unified network boundary.
///
/// [RequestEngine.execute] returns this in [RequestEngineResult.failure]
/// instead of throwing it. Branch on [code], which is stable, rather than on
/// [message].
class RequestFailure implements Exception {
  /// Creates a failure of category [code] for [uri].
  const RequestFailure({
    required this.code,
    required this.message,
    required this.uri,
    this.cause,
    this.stackTrace,
  });

  /// The stable category of this failure.
  final RequestFailureCode code;

  /// A human-readable description of the failure.
  ///
  /// For a policy rejection, this is the validator's reason when it gave one.
  final String message;

  /// The URL the failure applies to.
  ///
  /// This is usually the logical target being requested, including a rejected
  /// redirect target. Proxy-stage policy failures report the proxy endpoint,
  /// a redirect loop reports the repeated URL, and an opaque transport's
  /// invalid final URL is reported as returned.
  final Uri uri;

  /// The underlying error, such as a transport or validator exception.
  final Object? cause;

  /// The stack trace for [cause], if available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'RequestFailure(${code.name}): $message';
}

/// Complete outcome of one logical request and all of its redirect hops.
class RequestEngineResult {
  /// Creates an outcome; [RequestEngine.execute] normally builds these.
  const RequestEngineResult({
    required this.originalUrl,
    required this.finalUrl,
    required this.redirects,
    required this.duration,
    required this.capabilities,
    this.response,
    this.failure,
  });

  /// The URL passed to [RequestEngine.execute], before normalization.
  final Uri originalUrl;

  /// The logical URL of the last target reached or attempted.
  ///
  /// This is normally the last URL requested. A redirect target that passed
  /// the redirect checks becomes [finalUrl] before it is requested, so when
  /// the request policy rejects that target, or the deadline or cancellation
  /// ends the operation before it is sent, [finalUrl] is that target.
  ///
  /// A redirect that fails those checks leaves [finalUrl] at the URL that
  /// returned the redirect. This covers [RequestFailureCode.redirectLimit],
  /// [RequestFailureCode.redirectLoop], and
  /// [RequestFailureCode.invalidRedirect]; [RequestFailure.uri] names the
  /// offending URL.
  ///
  /// When an opaque transport follows redirects itself, this is the final URL
  /// the transport reported, unless that URL is invalid. A
  /// [RequestFailureCode.invalidTarget] failure keeps the URL passed in. It
  /// never contains a [FetchOptions.proxyUrl] rewrite.
  final Uri finalUrl;

  /// Redirect hops observed and validated by MetaLink.
  ///
  /// This is empty when an uninspectable browser transport follows redirects
  /// opaquely in compatibility mode, even if [finalUrl] differs from
  /// [originalUrl]. Inspect [capabilities] before relying on hop details.
  final List<RedirectHop> redirects;

  /// Total time spent on the operation, including policy checks and all hops.
  final Duration duration;

  /// Capabilities of the fetcher that served the request.
  ///
  /// A fetcher that does not implement [CapabilityAwareFetcher] reports
  /// [FetcherCapabilities.legacy].
  final FetcherCapabilities capabilities;

  /// The last response received, or `null` when the request ended before its
  /// first hop or the response was discarded by a
  /// [RequestFailureCode.unsupportedCapability] failure.
  ///
  /// Its [FetchResponse.url] is the logical URL rather than a proxy URL. It is
  /// a redirect response when redirects are disabled or a redirect failed, and
  /// it carries the transport error when the transport failed.
  final FetchResponse? response;

  /// Why the request failed, or `null` when it completed.
  ///
  /// A completed request can still have a non-2xx [response] status.
  final RequestFailure? failure;

  /// Whether the request completed without a [failure] or transport error.
  ///
  /// This does not inspect the HTTP status; use [FetchResponse.isOk] on
  /// [response] for that.
  bool get isSuccess => failure == null && response?.error == null;

  /// Adapts this richer outcome to the legacy low-level response contract.
  FetchResponse toFetchResponse() {
    final value = response;
    return FetchResponse(
      url: finalUrl,
      statusCode: value?.statusCode,
      headers: value?.headers ?? const <String, String>{},
      bodyBytes: value?.bodyBytes ?? const <int>[],
      truncated: value?.truncated ?? false,
      duration: duration,
      error: failure ?? value?.error,
      stackTrace: failure?.stackTrace ?? value?.stackTrace,
    );
  }
}

/// Central request, redirect, policy, proxy, header, and deadline engine.
class RequestEngine {
  /// Creates an engine that sends every hop through `fetcher`.
  ///
  /// The engine never closes `fetcher`; its owner remains responsible for it.
  RequestEngine({required this._fetcher});

  final Fetcher _fetcher;
  static const UrlResolver _urlResolver = UrlResolver();
  static const String _defaultUserAgent =
      'MetaLink (+https://github.com/omar-hanafy/metalink)';

  /// Performs one logical request to [startUrl] and returns its outcome.
  ///
  /// Network, policy, and lifetime failures are reported in
  /// [RequestEngineResult.failure] instead of being thrown. Before every hop,
  /// the target is validated by [FetchOptions.requestPolicy], and so is the
  /// rewritten endpoint when [FetchOptions.proxyUrl] applies. Redirects are
  /// followed only while [FetchOptions.followRedirects] allows it, up to
  /// [FetchOptions.maxRedirects] hops, and sensitive headers and URL userinfo
  /// credentials are removed at the trust boundaries the policy defines.
  ///
  /// The operation stops at [FetchOptions.totalTimeout] or at the deadline of
  /// [context], whichever is earlier, and when the context's
  /// [RequestContext.cancellationSignal] completes. Each attempt is also
  /// limited by [FetchOptions.timeout].
  ///
  /// [purpose] is passed to the policy. For [RequestPurpose.oEmbed],
  /// [RequestPurpose.manifest], and [RequestPurpose.enrichment], sensitive
  /// headers are dropped unless
  /// [RequestPolicy.forwardSensitiveHeadersToEnrichments] is `true`, and URL
  /// userinfo is always dropped.
  ///
  /// [strategy] selects the HTTP methods. With
  /// [RequestMethodStrategy.headWithGetFallback] or
  /// [RequestMethodStrategy.headThenGet], a failed HEAD falls back to GET
  /// unless the operation deadline elapsed or the caller cancelled. A HEAD
  /// that exceeds only its own [FetchOptions.timeout] still falls back while
  /// operation budget remains.
  ///
  /// [headers] are merged case-insensitively over [FetchOptions.headers] and
  /// the user agent, and win on conflicts. [maxBytes] caps each GET body and
  /// defaults to [FetchOptions.maxBytes] when `null`.
  ///
  /// For [RequestMethodStrategy.headThenGet], [shouldFetchBodyAfterHead]
  /// receives a HEAD response that is neither an error nor a redirect and
  /// decides whether to send the GET. When it returns `false`, the HEAD
  /// response is the result. When it is `null`, the GET is always sent.
  Future<RequestEngineResult> execute(
    Uri startUrl, {
    required FetchOptions options,
    RequestContext? context,
    RequestPurpose purpose = RequestPurpose.document,
    RequestMethodStrategy strategy = RequestMethodStrategy.get,
    Map<String, String>? headers,
    int? maxBytes,
    bool Function(FetchResponse response)? shouldFetchBodyAfterHead,
  }) async {
    final stopwatch = Stopwatch()..start();
    final operationContext = RequestContext.forOperation(
      totalTimeout: options.totalTimeout,
      parent: context,
    );
    final policy = options.requestPolicy;
    final capabilities = _capabilities;
    final redirects = <RedirectHop>[];
    final originalUrl = startUrl;
    var current = startUrl;
    FetchResponse? response;
    var getOnly = strategy == RequestMethodStrategy.get;

    RequestEngineResult finish({RequestFailure? failure}) {
      stopwatch.stop();
      return RequestEngineResult(
        originalUrl: originalUrl,
        finalUrl: current,
        redirects: List<RedirectHop>.unmodifiable(redirects),
        duration: stopwatch.elapsed,
        capabilities: capabilities,
        response: response,
        failure: failure,
      );
    }

    final normalizedInitial = _normalizeHttpTarget(startUrl);
    if (normalizedInitial == null) {
      return finish(
        failure: RequestFailure(
          code: RequestFailureCode.invalidTarget,
          message: 'Target must be an absolute HTTP(S) URL.',
          uri: startUrl,
        ),
      );
    }
    // URL userinfo is a credential: dart:io, for one, sends it as
    // `Authorization: Basic`. Enrichment URLs inherit it from the document URL
    // through relative resolution, so it never travels with them.
    final stripUserInfo = _isEnrichment(purpose);
    current = stripUserInfo
        ? _withoutUserInfo(normalizedInitial)
        : normalizedInitial;

    final capabilityFailure = _capabilityFailure(capabilities, policy, current);
    if (capabilityFailure != null) {
      return finish(failure: capabilityFailure);
    }

    var requestHeaders = policy.headersForInitial(
      purpose,
      _mergeHeaders(options, headers),
    );
    final visited = <String>{_visitKey(current)};

    while (true) {
      final lifetimeFailure = _lifetimeFailure(operationContext, current);
      if (lifetimeFailure != null) return finish(failure: lifetimeFailure);

      late final RequestPolicyDecision admission;
      try {
        admission = await _raceWithLifetime(
          policy.validateTarget(
            RequestTarget(
              uri: current,
              purpose: purpose,
              stage: redirects.isEmpty
                  ? RequestTargetStage.initial
                  : RequestTargetStage.redirect,
              redirectCount: redirects.length,
              previousUri: redirects.isEmpty ? null : redirects.last.from,
            ),
          ),
          operationContext,
          current,
        );
      } on Object catch (error, stackTrace) {
        final lifetimeFailure = _failureFromLifetimeError(
          error,
          stackTrace,
          current,
        );
        return finish(
          failure:
              lifetimeFailure ??
              RequestFailure(
                code: RequestFailureCode.policyRejected,
                message: 'Request target policy evaluation failed closed.',
                uri: current,
                cause: error,
                stackTrace: stackTrace,
              ),
        );
      }
      if (!admission.allowed) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.policyRejected,
            message: admission.reason ?? 'Request target rejected by policy.',
            uri: current,
          ),
        );
      }

      Uri requestUrl;
      var hopHeaders = requestHeaders;
      try {
        requestUrl = _applyProxy(
          current,
          options.proxyUrl,
          includeUserInfo: policy.forwardSensitiveHeadersThroughProxy,
        );
      } on Object catch (error, stackTrace) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.proxyConfiguration,
            message: 'Proxy configuration did not produce a valid target.',
            uri: current,
            cause: error,
            stackTrace: stackTrace,
          ),
        );
      }

      if (requestUrl != current) {
        late final RequestPolicyDecision proxyAdmission;
        try {
          proxyAdmission = await _raceWithLifetime(
            policy.validateProxyTarget(
              RequestTarget(
                uri: requestUrl,
                purpose: purpose,
                stage: RequestTargetStage.proxy,
                redirectCount: redirects.length,
                previousUri: current,
              ),
            ),
            operationContext,
            requestUrl,
          );
        } on Object catch (error, stackTrace) {
          final lifetimeFailure = _failureFromLifetimeError(
            error,
            stackTrace,
            requestUrl,
          );
          return finish(
            failure:
                lifetimeFailure ??
                RequestFailure(
                  code: RequestFailureCode.policyRejected,
                  message: 'Proxy target policy evaluation failed closed.',
                  uri: requestUrl,
                  cause: error,
                  stackTrace: stackTrace,
                ),
          );
        }
        if (!proxyAdmission.allowed) {
          return finish(
            failure: RequestFailure(
              code: RequestFailureCode.policyRejected,
              message:
                  proxyAdmission.reason ?? 'Proxy target rejected by policy.',
              uri: requestUrl,
            ),
          );
        }
        hopHeaders = policy.headersForProxy(hopHeaders);
      }

      final transportOptions = _transportOptions(
        options,
        operationContext,
        allowUninspectableRedirects: requestUrl == current,
      );
      if (transportOptions == null) {
        return finish(
          failure:
              _lifetimeFailure(operationContext, current) ??
              RequestFailure(
                code: RequestFailureCode.timeout,
                message: 'The complete request deadline elapsed.',
                uri: current,
              ),
        );
      }

      response = await _performHop(
        logicalUrl: current,
        requestUrl: requestUrl,
        options: transportOptions,
        context: operationContext,
        headers: hopHeaders,
        maxBytes: maxBytes,
        strategy: strategy,
        getOnly: getOnly,
        shouldFetchBodyAfterHead: shouldFetchBodyAfterHead,
      );
      final transportResponseUrl = response.url;
      response = _withLogicalUrl(response, current);

      if (strategy == RequestMethodStrategy.headThenGet &&
          response._wasGetResponse) {
        getOnly = true;
      }

      if (response.error != null) {
        return finish(failure: _transportFailure(current, response));
      }

      // A fetcher that is assumed or declared inspectable must return
      // redirects unfollowed. A different response URL proves it followed one
      // on its own, so no hop after the first was validated. Discard the
      // response rather than hand unvalidated content to the caller.
      if (policy.requireInspectableRedirects &&
          capabilities.redirectHandling ==
              RedirectHandlingCapability.inspectable &&
          !_isSameTarget(requestUrl, transportResponseUrl)) {
        response = null;
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.unsupportedCapability,
            message:
                'The fetcher followed a redirect itself, so the request '
                'policy could not validate every hop.',
            uri: current,
          ),
        );
      }

      if (capabilities.redirectHandling ==
              RedirectHandlingCapability.unavailable &&
          transportOptions.followRedirects &&
          requestUrl == current &&
          transportResponseUrl != requestUrl) {
        final normalizedTransportFinal = _normalizeHttpTarget(
          transportResponseUrl,
        );
        if (normalizedTransportFinal == null) {
          return finish(
            failure: RequestFailure(
              code: RequestFailureCode.invalidRedirect,
              message: 'The transport returned an invalid final URL.',
              uri: transportResponseUrl,
            ),
          );
        }
        current = normalizedTransportFinal;
        response = _withLogicalUrl(response, current);
        return finish();
      }

      final location = _headerValue(response.headers, 'location');
      final isRedirect = _isRedirect(response.statusCode, location);
      if (!isRedirect || !options.followRedirects) {
        return finish();
      }
      if (options.maxRedirects <= 0) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.redirectLimit,
            message: 'Too many redirects (max: ${options.maxRedirects}).',
            uri: current,
          ),
        );
      }

      final next = _urlResolver.resolve(current, location);
      if (next == null) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.invalidRedirect,
            message: 'Redirect Location is not a valid HTTP(S) URL.',
            uri: current,
          ),
        );
      }
      var normalizedNext = _normalizeHttpTarget(next);
      if (normalizedNext != null &&
          (stripUserInfo ||
              (policy.stripSensitiveHeadersOnCrossOriginRedirect &&
                  !_isSameOrigin(current, normalizedNext)))) {
        normalizedNext = _withoutUserInfo(normalizedNext);
      }
      if (normalizedNext == null) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.invalidRedirect,
            message: 'Redirect Location is not a valid HTTP(S) URL.',
            uri: current,
          ),
        );
      }

      if (!visited.add(_visitKey(normalizedNext))) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.redirectLoop,
            message: 'Redirect loop detected.',
            uri: normalizedNext,
          ),
        );
      }
      if (redirects.length >= options.maxRedirects) {
        return finish(
          failure: RequestFailure(
            code: RequestFailureCode.redirectLimit,
            message: 'Too many redirects (max: ${options.maxRedirects}).',
            uri: current,
          ),
        );
      }

      final previous = current;
      redirects.add(
        RedirectHop(
          from: previous,
          to: normalizedNext,
          statusCode: response.statusCode ?? 0,
          location: location,
        ),
      );
      requestHeaders = policy.headersForRedirect(
        previous,
        normalizedNext,
        requestHeaders,
      );
      current = normalizedNext;
    }
  }

  FetcherCapabilities get _capabilities {
    final fetcher = _fetcher;
    return fetcher is CapabilityAwareFetcher
        ? (fetcher as CapabilityAwareFetcher).capabilities
        : const FetcherCapabilities.legacy();
  }

  RequestFailure? _capabilityFailure(
    FetcherCapabilities capabilities,
    RequestPolicy policy,
    Uri uri,
  ) {
    if (!policy.requireInspectableRedirects ||
        capabilities.redirectHandling ==
            RedirectHandlingCapability.inspectable) {
      return null;
    }
    return RequestFailure(
      code: RequestFailureCode.unsupportedCapability,
      message:
          capabilities.limitation ??
          'The transport cannot guarantee inspectable redirect hops.',
      uri: uri,
    );
  }

  Future<FetchResponse> _performHop({
    required Uri logicalUrl,
    required Uri requestUrl,
    required FetchOptions options,
    required RequestContext context,
    required Map<String, String> headers,
    required int? maxBytes,
    required RequestMethodStrategy strategy,
    required bool getOnly,
    required bool Function(FetchResponse response)? shouldFetchBodyAfterHead,
  }) async {
    if (strategy == RequestMethodStrategy.get || getOnly) {
      return _get(logicalUrl, requestUrl, options, context, headers, maxBytes);
    }

    final head = await _head(logicalUrl, requestUrl, options, context, headers);
    if (strategy == RequestMethodStrategy.head) return head;

    // The operation deadline or caller cancellation ends the logical request.
    // Match the deadline by its marker type rather than by the context clock:
    // the deadline timer can fire just before the context observes expiry, and
    // a fallback GET started in that interval would outlive the operation. A
    // per-attempt timeout is an ordinary HEAD failure and falls through to the
    // GET fallback, which `_transportOptions` still refuses once no budget
    // remains.
    if (head.error
        case _OperationDeadlineElapsed() || FetchCancellationException()) {
      return head;
    }

    final fallback = strategy == RequestMethodStrategy.headWithGetFallback
        ? head.error != null || head.statusCode == 405 || head.statusCode == 501
        : _shouldFallbackFromDocumentHead(head);
    if (fallback) {
      final getOptions = _transportOptions(options, context);
      if (getOptions == null) {
        return _lifetimeResponse(logicalUrl, context, isGet: true);
      }
      return _get(
        logicalUrl,
        requestUrl,
        getOptions,
        context,
        headers,
        strategy == RequestMethodStrategy.headWithGetFallback ? 0 : maxBytes,
      );
    }

    if (strategy == RequestMethodStrategy.headThenGet &&
        !_isRedirect(head.statusCode, _headerValue(head.headers, 'location')) &&
        (shouldFetchBodyAfterHead?.call(head) ?? true)) {
      final getOptions = _transportOptions(options, context);
      if (getOptions == null) {
        return _lifetimeResponse(logicalUrl, context, isGet: true);
      }
      return _get(
        logicalUrl,
        requestUrl,
        getOptions,
        context,
        headers,
        maxBytes,
      );
    }
    return head;
  }

  Future<FetchResponse> _get(
    Uri logicalUrl,
    Uri requestUrl,
    FetchOptions options,
    RequestContext context,
    Map<String, String> headers,
    int? maxBytes,
  ) {
    final fetcher = _fetcher;
    final operation = fetcher is AbortableFetcher
        ? fetcher.get(
            requestUrl,
            options: options,
            headers: headers,
            maxBytes: maxBytes,
            abortTrigger: context.cancellationSignal,
          )
        : fetcher.get(
            requestUrl,
            options: options,
            headers: headers,
            maxBytes: maxBytes,
          );
    return _containAndRace(operation, logicalUrl, context, isGet: true);
  }

  Future<FetchResponse> _head(
    Uri logicalUrl,
    Uri requestUrl,
    FetchOptions options,
    RequestContext context,
    Map<String, String> headers,
  ) {
    final fetcher = _fetcher;
    final operation = fetcher is AbortableFetcher
        ? fetcher.head(
            requestUrl,
            options: options,
            headers: headers,
            abortTrigger: context.cancellationSignal,
          )
        : fetcher.head(requestUrl, options: options, headers: headers);
    return _containAndRace(operation, logicalUrl, context, isGet: false);
  }

  Future<FetchResponse> _containAndRace(
    Future<FetchResponse> operation,
    Uri logicalUrl,
    RequestContext context, {
    required bool isGet,
  }) async {
    try {
      final result = await _raceWithLifetime(operation, context, logicalUrl);
      return _MethodFetchResponse.from(result, wasGetResponse: isGet);
    } on Object catch (error, stackTrace) {
      return _MethodFetchResponse(
        url: logicalUrl,
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        truncated: false,
        duration: Duration.zero,
        error: error,
        stackTrace: stackTrace,
        wasGetResponse: isGet,
      );
    }
  }

  static Future<T> _raceWithLifetime<T>(
    Future<T> operation,
    RequestContext context,
    Uri uri,
  ) async {
    final races = <Future<T>>[operation];
    Timer? deadlineTimer;
    final remaining = context.remaining;
    if (remaining != null) {
      final deadline = Completer<T>();
      deadlineTimer = startDeadlineTimer(
        remaining,
        () => deadline.completeError(_OperationDeadlineElapsed()),
      );
      races.add(deadline.future);
    }

    final cancellation = context.cancellationSignal;
    _CancellationRelay? relay;
    if (cancellation != null) {
      relay = _CancellationRelay(uri).._listen(cancellation);
      races.add(relay.future);
    }

    try {
      return await Future.any<T>(races);
    } finally {
      deadlineTimer?.cancel();
      // The signal keeps its listener until it completes. Releasing the relay
      // leaves that listener holding an empty relay instead of this race and
      // its result.
      relay?.release();
    }
  }

  FetchOptions? _transportOptions(
    FetchOptions options,
    RequestContext context, {
    bool allowUninspectableRedirects = true,
  }) {
    final remaining = context.remaining;
    if (context.isCancelled ||
        (remaining != null && remaining <= Duration.zero)) {
      return null;
    }
    var timeout = options.timeout;
    if (remaining != null && remaining < timeout) timeout = remaining;
    // Headers, including the user agent, have already crossed the request
    // policy boundary and are supplied per call. Do not leave either source in
    // the transport options because a Fetcher may merge them back after the
    // policy stripped a sensitive value.
    return FetchOptions(
      timeout: timeout,
      totalTimeout: options.totalTimeout,
      userAgent: null,
      followRedirects:
          allowUninspectableRedirects &&
          _capabilities.redirectHandling ==
              RedirectHandlingCapability.unavailable &&
          options.followRedirects &&
          options.maxRedirects > 0,
      maxRedirects: options.maxRedirects,
      maxBytes: options.maxBytes,
      stopAfterHead: options.stopAfterHead,
      proxyUrl: options.proxyUrl,
      headers: const <String, String>{},
      requestPolicy: options.requestPolicy,
    );
  }

  static Map<String, String> _mergeHeaders(
    FetchOptions options,
    Map<String, String>? additional,
  ) {
    final result = <String, String>{};
    void add(Map<String, String> values) {
      for (final entry in values.entries) {
        result[entry.key.toLowerCase()] = entry.value;
      }
    }

    add(options.headers);
    if (!result.containsKey('user-agent')) {
      final configuredUserAgent = options.userAgent;
      result['user-agent'] =
          configuredUserAgent != null && configuredUserAgent.trim().isNotEmpty
          ? configuredUserAgent
          : _defaultUserAgent;
    }
    if (additional != null) add(additional);
    return result;
  }

  static Uri _applyProxy(
    Uri target,
    String? proxyUrl, {
    required bool includeUserInfo,
  }) {
    if (proxyUrl == null || proxyUrl.trim().isEmpty) return target;
    return UrlNormalizer.applyProxy(
      includeUserInfo ? target : _withoutUserInfo(target),
      proxyUrl,
    );
  }

  static bool _isEnrichment(RequestPurpose purpose) =>
      purpose == RequestPurpose.oEmbed ||
      purpose == RequestPurpose.manifest ||
      purpose == RequestPurpose.enrichment;

  static Uri _withoutUserInfo(Uri target) =>
      target.userInfo.isEmpty ? target : target.replace(userInfo: '');

  // Mirrors the origin comparison RequestPolicy uses for header stripping.
  static bool _isSameOrigin(Uri a, Uri b) {
    int effectivePort(Uri uri) => uri.hasPort
        ? uri.port
        : (uri.scheme.toLowerCase() == 'http' ? 80 : 443);
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        effectivePort(a) == effectivePort(b);
  }

  // Whether a reported response URL names the requested target. Userinfo is
  // ignored because some clients omit it from the reported URL without having
  // followed a redirect.
  static bool _isSameTarget(Uri requested, Uri reported) {
    final normalizedRequested = _normalizeHttpTarget(
      _withoutUserInfo(requested),
    );
    final normalizedReported = _normalizeHttpTarget(_withoutUserInfo(reported));
    return normalizedRequested != null &&
        normalizedReported != null &&
        normalizedRequested.toString() == normalizedReported.toString();
  }

  static Uri? _normalizeHttpTarget(Uri target) {
    final scheme = target.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || target.host.isEmpty) {
      return null;
    }
    try {
      return UrlNormalizer.normalizeForRequest(target);
    } on Object {
      return null;
    }
  }

  static String _visitKey(Uri target) =>
      UrlNormalizer.normalizeForRequest(target).toString();

  static RequestFailure? _lifetimeFailure(RequestContext context, Uri uri) {
    if (context.isCancelled) {
      return RequestFailure(
        code: RequestFailureCode.cancelled,
        message: 'The request was cancelled.',
        uri: uri,
      );
    }
    if (context.isExpired) {
      return RequestFailure(
        code: RequestFailureCode.timeout,
        message: 'The complete request deadline elapsed.',
        uri: uri,
      );
    }
    return null;
  }

  static RequestFailure _transportFailure(Uri uri, FetchResponse response) {
    final error = response.error!;
    final code = switch (error) {
      TimeoutException() => RequestFailureCode.timeout,
      FetchCancellationException() => RequestFailureCode.cancelled,
      _ => RequestFailureCode.transport,
    };
    return RequestFailure(
      code: code,
      message: switch (code) {
        RequestFailureCode.timeout => 'The request timed out.',
        RequestFailureCode.cancelled => 'The request was cancelled.',
        _ => 'The transport failed to complete the request.',
      },
      uri: uri,
      cause: error,
      stackTrace: response.stackTrace,
    );
  }

  static RequestFailure? _failureFromLifetimeError(
    Object error,
    StackTrace stackTrace,
    Uri uri,
  ) {
    if (error is TimeoutException) {
      return RequestFailure(
        code: RequestFailureCode.timeout,
        message: 'The complete request deadline elapsed.',
        uri: uri,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (error is FetchCancellationException) {
      return RequestFailure(
        code: RequestFailureCode.cancelled,
        message: 'The request was cancelled.',
        uri: uri,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  static FetchResponse _lifetimeResponse(
    Uri uri,
    RequestContext context, {
    required bool isGet,
  }) {
    final error = context.isCancelled
        ? FetchCancellationException(uri)
        : _OperationDeadlineElapsed();
    return _MethodFetchResponse(
      url: uri,
      statusCode: null,
      headers: const <String, String>{},
      bodyBytes: const <int>[],
      truncated: false,
      duration: Duration.zero,
      error: error,
      wasGetResponse: isGet,
    );
  }

  static FetchResponse _withLogicalUrl(FetchResponse response, Uri logicalUrl) {
    return _MethodFetchResponse(
      url: logicalUrl,
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: response.bodyBytes,
      truncated: response.truncated,
      duration: response.duration,
      error: response.error,
      stackTrace: response.stackTrace,
      wasGetResponse: response._wasGetResponse,
    );
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final needle = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == needle) return entry.value;
    }
    return null;
  }

  static bool _isRedirect(int? statusCode, String? location) {
    if (location == null || location.trim().isEmpty) return false;
    return statusCode == 300 ||
        statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  static bool _shouldFallbackFromDocumentHead(FetchResponse response) {
    final status = response.statusCode;
    return response.error != null ||
        status == null ||
        status == 405 ||
        status == 501 ||
        (status >= 400 && status < 600);
  }
}

/// The complete-operation deadline elapsed, as opposed to one attempt's
/// [FetchOptions.timeout].
///
/// It remains a [TimeoutException] so callers that match timeouts by type keep
/// working, while the engine can tell the terminal deadline apart from a
/// per-attempt timeout that should still allow a fallback request.
class _OperationDeadlineElapsed extends TimeoutException {
  _OperationDeadlineElapsed() : super('Complete request deadline elapsed');
}

/// Relays a caller-owned cancellation signal into one lifetime race.
///
/// A [Future] cannot drop a listener before it completes, so a listener on a
/// long-lived signal outlives the race that registered it. The listener
/// closures are created in [_listen] and capture only this relay, and
/// [release] drops the race's completer when the race ends. A signal that
/// never completes therefore retains this small object rather than the race
/// and the response it produced.
final class _CancellationRelay {
  _CancellationRelay(this._uri);

  final Uri _uri;
  Completer<Never>? _cancelled = Completer<Never>();

  /// Fails with a [FetchCancellationException] when the signal completes
  /// before [release]. Read it only before [release].
  Future<Never> get future => _cancelled!.future;

  /// Treats completion of [signal] with a value or an error as cancellation.
  void _listen(Future<void> signal) {
    signal
        .then<void>(
          (_) => _cancel(),
          onError: (Object _, StackTrace _) => _cancel(),
        )
        .ignore();
  }

  void _cancel() {
    _cancelled?.completeError(FetchCancellationException(_uri));
  }

  /// Detaches the race; a later signal completion does nothing.
  void release() {
    _cancelled = null;
  }
}

class _MethodFetchResponse extends FetchResponse {
  const _MethodFetchResponse({
    required super.url,
    required super.statusCode,
    required super.headers,
    required super.bodyBytes,
    required super.truncated,
    required super.duration,
    required this.wasGetResponse,
    super.error,
    super.stackTrace,
  });

  factory _MethodFetchResponse.from(
    FetchResponse response, {
    required bool wasGetResponse,
  }) {
    return _MethodFetchResponse(
      url: response.url,
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: response.bodyBytes,
      truncated: response.truncated,
      duration: response.duration,
      error: response.error,
      stackTrace: response.stackTrace,
      wasGetResponse: wasGetResponse,
    );
  }

  final bool wasGetResponse;
}

extension on FetchResponse {
  bool get _wasGetResponse =>
      this is _MethodFetchResponse &&
      (this as _MethodFetchResponse).wasGetResponse;
}
