import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The Shams emblem: a rounded square filled with the brand gradient and an
/// `auto_awesome` star inside.
///
/// Used by the login screen, the welcome surface and the chat header, so the
/// brand identity is one widget - restyling the emblem does not touch screens.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});

  /// Edge length of the rounded square.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: brandLinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.auto_awesome,
        size: size * 0.55,
        color: Colors.white,
      ),
    );
  }
}

/// "Shams" with a gradient underline - the wordmark next to the emblem, kept
/// as text (not an image) so the platform font and screen readers stay right.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.fontSize = 20});

  /// Font size of the word itself; the underline scales with it.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shams',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.1,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 3,
          width: fontSize * 2.4,
          decoration: BoxDecoration(
            gradient: brandLinearGradient(),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}
