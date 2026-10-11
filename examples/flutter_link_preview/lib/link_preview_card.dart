import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:metalink/metalink.dart';

class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({
    required this.metadata,
    required this.status,
    required this.elapsed,
    required this.cacheHit,
    this.titleSource,
    super.key,
  });

  final LinkMetadata metadata;
  final ExtractionStatus status;
  final Duration elapsed;
  final bool cacheHit;
  final String? titleSource;

  /// Width of the image column in the side-by-side layout.
  static const double _wideImageWidth = 380;

  /// Narrowest text column, at 1x text, that still reads well beside the
  /// image. It grows with the text scale so large text switches to the
  /// stacked layout instead of squeezing into a tall, narrow column.
  static const double _minWideBodyWidth = 340;

  /// Minimum height of the side-by-side layout, so short metadata still gets
  /// a generous image. Longer content makes the card taller.
  static const double _minWideHeight = 440;

  /// Font size used to turn the platform [TextScaler] into a layout factor.
  static const double _referenceFontSize = 16;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale =
        MediaQuery.textScalerOf(context).scale(_referenceFontSize) /
        _referenceFontSize;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >=
            _wideImageWidth + _minWideBodyWidth * math.max(1, textScale);
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: colorScheme.surfaceContainerLowest),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1E17112E),
                blurRadius: 42,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: wide
              // The text column decides the card height; the image fills
              // whatever height the text needs, so nothing is clipped.
              ? Stack(
                  children: [
                    PositionedDirectional(
                      start: 0,
                      top: 0,
                      bottom: 0,
                      width: _wideImageWidth,
                      child: _buildImage(context),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: _minWideHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: _wideImageWidth,
                        ),
                        child: _buildBody(context),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 230, child: _buildImage(context)),
                    _buildBody(context),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildImage(BuildContext context) {
    final image = metadata.images.firstOrNull;
    if (image == null) {
      return const _ImageFallback();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Page-supplied URL: Flutter's image loader does not apply MetaLink's
        // request policy. See "Request safety and images" in the README.
        Image.network(
          image.url.toString(),
          fit: BoxFit.cover,
          semanticLabel: image.alt,
          errorBuilder: (_, _, _) => const _ImageFallback(),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0x73000000)],
            ),
          ),
        ),
        PositionedDirectional(
          start: 18,
          bottom: 16,
          child: _KindBadge(kind: metadata.kind),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final icon = metadata.icons.firstOrNull;
    final host = metadata.resolvedUrl.host;
    final partial = status == ExtractionStatus.partial;

    return Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _Favicon(url: icon?.url),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metadata.siteName ?? host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Copy resolved URL',
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: metadata.resolvedUrl.toString()),
                  );
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(const SnackBar(content: Text('Link copied')));
                },
                icon: const Icon(Icons.content_copy_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            metadata.title ?? host,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          if (metadata.description case final description?) ...[
            const SizedBox(height: 12),
            Text(
              description,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _DiagnosticChip(
                icon: partial
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                label: partial ? 'Partial metadata' : 'Complete metadata',
              ),
              _DiagnosticChip(
                icon: cacheHit
                    ? Icons.bolt_rounded
                    : Icons.travel_explore_rounded,
                label: cacheHit ? 'Cache hit' : 'Fetched live',
              ),
              _DiagnosticChip(
                icon: Icons.timer_outlined,
                label: '${elapsed.inMilliseconds} ms',
              ),
              if (titleSource case final source?)
                _DiagnosticChip(
                  icon: Icons.hub_outlined,
                  label: 'Title: $source',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class LinkPreviewSkeleton extends StatefulWidget {
  const LinkPreviewSkeleton({super.key});

  @override
  State<LinkPreviewSkeleton> createState() => _LinkPreviewSkeletonState();
}

class _LinkPreviewSkeletonState extends State<LinkPreviewSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the platform "reduce motion" setting: show a static placeholder
    // instead of an endless pulse.
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      unawaited(_controller.repeat(reverse: true));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Loading link preview',
      container: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final color = Color.lerp(
            colorScheme.surfaceContainerHigh,
            colorScheme.surfaceContainerLow,
            _controller.value,
          )!;
          return Container(
            height: 360,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLowest.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FractionallySizedBox(
                  widthFactor: 0.7,
                  child: Container(
                    height: 24,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FractionallySizedBox(
                  widthFactor: 0.9,
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colorScheme.primaryContainer, colorScheme.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.public_rounded,
          size: 64,
          color: colorScheme.primary.withValues(alpha: 0.65),
        ),
      ),
    );
  }
}

class _Favicon extends StatelessWidget {
  const _Favicon({required this.url});

  final Uri? url;

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: 20,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: const Icon(Icons.language_rounded, size: 20),
    );
    final value = url;
    if (value == null) return fallback;

    return ClipOval(
      // Page-supplied URL: Flutter's image loader does not apply MetaLink's
      // request policy. See "Request safety and images" in the README.
      child: Image.network(
        value.toString(),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final LinkKind kind;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9181522),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          kind.name.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

class _DiagnosticChip extends StatelessWidget {
  const _DiagnosticChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(child: Text(label, style: theme.textTheme.labelMedium)),
          ],
        ),
      ),
    );
  }
}
