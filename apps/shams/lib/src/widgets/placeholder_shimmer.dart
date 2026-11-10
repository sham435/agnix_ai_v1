import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Loading placeholders for the conversation surfaces.
///
/// Purely static shapes by design: a repeating shimmer owns an animation
/// controller that never settles, which is exactly what leaves a test's
/// `pumpAndSettle` hanging (and a slow phone redrawing forever). The shape
/// outline alone communicates "turns are loading" the moment the screen opens.
class ConversationSkeleton extends StatelessWidget {
  const ConversationSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHigh.withValues(alpha: 0.5);

    Widget bar(double width, double height, {Alignment alignment = Alignment.centerLeft}) =>
        Align(
          alignment: alignment,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          bar(340, 12),
          const SizedBox(height: 10),
          bar(280, 12),
          const SizedBox(height: 24),
          bar(430, 64, alignment: Alignment.centerRight),
          const SizedBox(height: 28),
          bar(200, 10),
          const SizedBox(height: 10),
          bar(500, 10),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: bar(170, 10)),
          const SizedBox(height: 28),
          bar(420, 52, alignment: Alignment.centerRight),
          const SizedBox(height: 28),
          bar(260, 10),
          const SizedBox(height: 10),
          bar(460, 10),
          const Spacer(),
        ],
      ),
    );
  }
}

/// A wide row of brand-tinted gradient chips shown above the composer while
/// the conversation's first fetch resolves - a tiny nod at the brand palette
/// without owning an animation.
class ConversationListSkeleton extends StatelessWidget {
  const ConversationListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHigh.withValues(alpha: 0.5);
    return Column(
      children: [
        for (final i in List<int>.generate(5, (index) => index))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FractionallySizedBox(
                widthFactor: i.isEven ? 0.55 : 0.38,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      gradient: i == 0 ? brandLinearGradient() : null,
                      color: i == 0 ? null : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
