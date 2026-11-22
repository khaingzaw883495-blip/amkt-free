import 'package:flutter/material.dart';

/// The app-wide theme mode (v1.0.10: default is light blue).
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.light);

ThemeMode themeModeFromString(String mode) => switch (mode) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    };
