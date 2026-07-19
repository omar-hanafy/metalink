String? unsafeTargetReason(Uri uri) {
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host.isEmpty) return 'The request target has no host.';

  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host == 'metadata') {
    return 'Local and internal host names are not allowed.';
  }

  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) {
    return _unsafeIpv4Reason(ipv4);
  }

  if (_looksLikeAmbiguousNumericAddress(host)) {
    return 'Ambiguous numeric host representations are not allowed.';
  }

  if (host.contains(':')) {
    return unsafeIpv6LiteralReason(host);
  }

  return null;
}

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;

  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || !RegExp(r'^\d+$').hasMatch(part)) return null;
    if (part.length > 1 && part.startsWith('0')) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    bytes.add(value);
  }
  return bytes;
}

String? _unsafeIpv4Reason(List<int> address) {
  final a = address[0];
  final b = address[1];
  final c = address[2];

  final isNonPublic =
      a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 0 && c == 0) ||
      (a == 192 && b == 0 && c == 2) ||
      (a == 192 && b == 168) ||
      (a == 198 && (b == 18 || b == 19)) ||
      (a == 198 && b == 51 && c == 100) ||
      (a == 203 && b == 0 && c == 113) ||
      a >= 224;

  return isNonPublic ? 'Non-public IPv4 targets are not allowed.' : null;
}

bool _looksLikeAmbiguousNumericAddress(String host) {
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) return true;
  final numericComponents = host.split('.');
  return numericComponents.isNotEmpty &&
      numericComponents.every(
        (component) =>
            RegExp(r'^\d+$').hasMatch(component) ||
            RegExp(r'^0x[0-9a-f]+$', caseSensitive: false).hasMatch(component),
      );
}

/// Returns why an IPv6 literal is unsafe, or `null` for a valid global target.
///
/// This package-internal entry point is public only so the parser's fail-closed
/// behavior can be tested with malformed strings that [Uri] refuses to create.
String? unsafeIpv6LiteralReason(String host) {
  var normalized = host.toLowerCase();
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (normalized.contains('%')) {
    return 'Scoped IPv6 targets are not allowed.';
  }

  final address = _parseIpv6(normalized);
  if (address == null) {
    return 'Invalid or ambiguous IPv6 targets are not allowed.';
  }

  final isUnspecified = address.every((group) => group == 0);
  final isLoopback =
      address.take(7).every((group) => group == 0) && address[7] == 1;
  if (isUnspecified || isLoopback) {
    return 'Unspecified and loopback IPv6 targets are not allowed.';
  }
  if ((address[0] & 0xfe00) == 0xfc00) {
    return 'Unique-local IPv6 targets are not allowed.';
  }
  if ((address[0] & 0xffc0) == 0xfe80) {
    return 'Link-local IPv6 targets are not allowed.';
  }
  if ((address[0] & 0xffc0) == 0xfec0) {
    return 'Site-local IPv6 targets are not allowed.';
  }
  if ((address[0] & 0xff00) == 0xff00) {
    return 'Multicast IPv6 targets are not allowed.';
  }
  if (address[0] == 0x2001 && address[1] == 0x0db8) {
    return 'Documentation IPv6 targets are not allowed.';
  }

  final embeddedIpv4 = _embeddedIpv4Address(address);
  if (embeddedIpv4 != null) {
    return _unsafeIpv4Reason(embeddedIpv4);
  }

  return null;
}

List<int>? _parseIpv6(String input) {
  if (input.isEmpty) return null;

  final compressionIndex = input.indexOf('::');
  final hasCompression = compressionIndex >= 0;
  if (hasCompression && compressionIndex != input.lastIndexOf('::')) {
    return null;
  }
  if (!hasCompression && (input.startsWith(':') || input.endsWith(':'))) {
    return null;
  }

  final leftText = hasCompression
      ? input.substring(0, compressionIndex)
      : input;
  final rightText = hasCompression ? input.substring(compressionIndex + 2) : '';
  final leftTokens = _splitIpv6Side(leftText);
  final rightTokens = _splitIpv6Side(rightText);
  if (leftTokens == null || rightTokens == null) return null;

  final left = _parseIpv6Tokens(
    leftTokens,
    mayContainTrailingIpv4: !hasCompression,
  );
  final right = _parseIpv6Tokens(rightTokens, mayContainTrailingIpv4: true);
  if (left == null || right == null) return null;

  final explicitGroups = left.length + right.length;
  if (!hasCompression) {
    return explicitGroups == 8 ? left : null;
  }
  final compressedGroups = 8 - explicitGroups;
  if (compressedGroups < 1) return null;
  return <int>[...left, ...List<int>.filled(compressedGroups, 0), ...right];
}

List<String>? _splitIpv6Side(String value) {
  if (value.isEmpty) return const <String>[];
  final tokens = value.split(':');
  return tokens.any((token) => token.isEmpty) ? null : tokens;
}

List<int>? _parseIpv6Tokens(
  List<String> tokens, {
  required bool mayContainTrailingIpv4,
}) {
  final groups = <int>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.contains('.')) {
      if (!mayContainTrailingIpv4 || index != tokens.length - 1) return null;
      final ipv4 = _parseIpv4(token);
      if (ipv4 == null) return null;
      groups
        ..add((ipv4[0] << 8) | ipv4[1])
        ..add((ipv4[2] << 8) | ipv4[3]);
      continue;
    }

    if (!RegExp(r'^[0-9a-f]{1,4}$').hasMatch(token)) return null;
    final value = int.tryParse(token, radix: 16);
    if (value == null) return null;
    groups.add(value);
  }
  return groups;
}

List<int>? _embeddedIpv4Address(List<int> address) {
  final isMapped =
      address.take(5).every((group) => group == 0) && address[5] == 0xffff;
  final isCompatible = address.take(6).every((group) => group == 0);
  final isNat64 =
      address[0] == 0x0064 &&
      address[1] == 0xff9b &&
      address.skip(2).take(4).every((group) => group == 0);
  if (!isMapped && !isCompatible && !isNat64) return null;

  return <int>[
    address[6] >> 8,
    address[6] & 0xff,
    address[7] >> 8,
    address[7] & 0xff,
  ];
}
