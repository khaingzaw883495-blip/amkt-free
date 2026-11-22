import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tzlocal;

import 'services/ad_config.dart';
import 'services/app_store.dart';
import 'services/fcm_service.dart';
import 'services/notifications.dart';
import 'services/redeem_code.dart';
import 'services/theme_mode.dart';
import 'services/vpn_engine.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase Analytics + FCM: best-effort, never blocks app startup.
  try {
    await Firebase.initializeApp();
    await FirebaseAnalytics.instance.logAppOpen();
  } catch (_) {}
  try {
    tz.initializeTimeZones();
    tzlocal.setLocalLocation(tzlocal.getLocation('Asia/Yangon'));
  } catch (_) {}
  final store = await AppStore.load();
  appThemeMode.value = themeModeFromString(store.themeMode);
  await NotificationService.init();
  // v1.0.10: Firebase Cloud Messaging push notifications (best-effort).
  unawaited(FcmService.init(isPaid: store.hasPaidAccess));
  unawaited(VpnEngine.instance
      .init(killSwitch: store.killSwitch)
      .catchError((_) {}));
  unawaited(AdConfigService.refresh());
  unawaited(NoAdsCodeService.revalidateStoredCode(store).catchError((_) {}));
  runApp(const AmktVpnApp());
  if (!store.notifPermissionAsked) {
    unawaited(store.markNotifPermissionAsked());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(NotificationService.requestPermission());
    });
  }
}

class AmktVpnApp extends StatelessWidget {
  const AmktVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'AMKT VPN',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: mode,
          home: const MainScreen(),
        );
      },
    );
  }

  /// v1.0.10: Soft light-blue theme (အပြာနု) — clean airy surfaces, crisp
  /// white cards, sky-blue accents, high-contrast dark slate typography.
  static final ThemeData _lightTheme = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF1D8FE1),
      brightness: Brightness.light,
    ).copyWith(
      primary: const Color(0xFF1D8FE1),
      secondary: const Color(0xFF0EA5E9),
      surface: const Color(0xFFFFFFFF),
      onSurface: const Color(0xFF0F172A),
    ),
    scaffoldBackgroundColor: const Color(0xFFEAF4FF),
    cardColor: const Color(0xFFFFFFFF),
    cardTheme: CardThemeData(
      color: const Color(0xFFFFFFFF),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFD0E5FF), width: 1),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFEAF4FF),
      foregroundColor: Color(0xFF0F172A),
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFFFFFFFF),
      selectedItemColor: Color(0xFF1D8FE1),
      unselectedItemColor: Color(0xFF64748B),
      elevation: 8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFBFDBFE)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFBFDBFE)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1D8FE1), width: 1.5),
      ),
      hintStyle: const TextStyle(color: Color(0xFF64748B)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1D8FE1),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF0369A1),
        side: const BorderSide(color: Color(0xFF93C5FD)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      ),
    ),
  );

  static final ThemeData _darkTheme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C3AED),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF8B5CF6),
      secondary: const Color(0xFF22D3EE),
    ),
    scaffoldBackgroundColor: const Color(0xFF120E2B),
    cardColor: const Color(0xFF1E1A3A),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF120E2B),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF1E1A3A),
      selectedItemColor: Color(0xFF8B5CF6),
      unselectedItemColor: Colors.white70,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF22D3EE), width: 1.5),
      ),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF7C3AED),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      ),
    ),
  );
}
