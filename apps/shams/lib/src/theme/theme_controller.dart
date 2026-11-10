import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A backing store for [ThemeController], so the choice of theme mode survives
/// launches without coupling the controller to a specific plugin.
abstract class ThemeStore {
  Future<ThemeMode?> load();
  Future<void> save(ThemeMode mode);
}

/// The [ThemeStore] backed by `shared_preferences`.
///
/// Failures are swallowed on purpose: a missed preference is cosmetic (the
/// selector just falls back to system), while rethrowing would turn a
/// surface-level nicety into a hard dependency of the app shell.
class SharedPreferencesThemeStore implements ThemeStore {
  static const _key = 'shams.theme_mode';

  @override
  Future<ThemeMode?> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final name = preferences.getString(_key);
      if (name == null) return null;
      for (final mode in ThemeMode.values) {
        if (mode.name == name) return mode;
      }
      return null;
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> save(ThemeMode mode) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_key, mode.name);
    } on Exception {
      // Unsupported platform or storage failure: the choice applies to this
      // session only, nothing to recover.
    }
  }
}

/// Owns the app's [ThemeMode] - the `system | light | dark` choice.
///
/// A [ChangeNotifier] rather than scaffolding for a state package: the app has
/// no Riverpod (and the brief says preserve the architecture), so three lines
/// of notifier keeps the presentational widgets identical to what they would
/// consume from a bigger system.
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeStore? store})
    : _store = store ?? SharedPreferencesThemeStore();

  final ThemeStore _store;

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// Reads the stored choice and applies it.
  ///
  /// Called once from the app shell's `initState`; before the answer arrives
  /// the mode stays the default (system).
  Future<void> load() async {
    final stored = await _store.load();
    if (stored == null || stored == _mode) return;
    _mode = stored;
    notifyListeners();
  }

  /// Switches the mode, notifies the tree and persists the choice.
  void setMode(ThemeMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    unawaitedSave(mode);
  }

  // The save is fire-and-forget: a slow disk write must not stall the
  // selector's rebuild.
  Future<void> unawaitedSave(ThemeMode mode) async {
    await _store.save(mode);
  }
}

/// Gives the widget tree access to [ThemeController].
///
/// The theme setting lives "above" `MaterialApp` (the mode selects between its
/// themes), so an inherited scope is the one way for widgets in screens - the
/// role of a Provider dependency in other apps - to reach it.
class ThemeScope extends InheritedWidget {
  const ThemeScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final ThemeController controller;

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(
      scope != null,
      'ThemeScope.of called outside a ThemeScope - is the widget under ShamsApp?',
    );
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(ThemeScope oldWidget) =>
      oldWidget.controller != controller;
}
