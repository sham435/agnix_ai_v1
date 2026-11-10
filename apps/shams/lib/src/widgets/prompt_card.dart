import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The starter prompts the welcome surface and the empty thread offer.
///
/// The labels are exactly what lands in the composer (or, from the welcome
/// surface, what becomes the conversation's first turn through
/// `POST /api/v1/conversations {"content": ...}` - nothing is canned text).
const List<String> promptSuggestions = <String>[
  'Draft a welcome message',
  'Explain how this API works',
  'Brainstorm three feature ideas',
  'Summarize this project',
];

/// One selectable prompt card.
///
/// The laminate is a filled rounded [Material] + [InkWell]; a small gradient
/// dot marks it as one of the surfaces the brief grants the brand gradient.
/// Press feedback comes from the ink splash; hover/focus states come free.
class PromptCard extends StatelessWidget {
  const PromptCard({required this.label, required this.onSelected, super.key});

  /// The prompt text carried to [onSelected] when tapped.
  final String label;

  /// Called with [label] when the card is tapped.
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return Semantics(
      button: true,
      child: Material(
        shape: shape,
        color: schemeSurface(context),
        child: InkWell(
          onTap: () => onSelected?.call(label),
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: brandLinearGradient(),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                // Loose flex: the label sizes to its text but yields to the
                // card's width constraint by wrapping, so no single surface's
                // font metrics (test fonts render every glyph at full em
                // width) can push the row past its box.
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The nested-surface fill of the ambient brightness.
  Color schemeSurface(BuildContext context) =>
      chipColor(Theme.of(context).brightness);
}
