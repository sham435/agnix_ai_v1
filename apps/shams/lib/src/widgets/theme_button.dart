import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';

/// The theme selector: one button, a three-choice menu.
///
/// Appears in every header (login, home, chat) through [ThemeScope], so the
/// system/light/dark choice is reachable from anywhere the spec's headers name
/// it. The icon communicates the *current* mode without opening the menu.
class ThemeButton extends StatelessWidget {
  const ThemeButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    final mode = controller.mode;

    return PopupMenuButton<ThemeMode>(
      tooltip: 'Theme',
      onSelected: controller.setMode,
      icon: Icon(Icons.contrast, color: Theme.of(context).colorScheme.onSurface),
      itemBuilder: (context) => [
        for (final choice in ThemeMode.values)
          CheckedPopupMenuItem<ThemeMode>(
            value: choice,
            checked: choice == mode,
            child: Text(_label(choice)),
          ),
      ],
    );
  }

  String _label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}
