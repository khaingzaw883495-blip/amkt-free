import 'package:flutter/services.dart';

/// Native Android helpers via MethodChannel `amktvpn/system`
/// (battery optimization status/request + hotspot settings).
class SystemHelper {
  SystemHelper._();

  static const _channel = MethodChannel('amktvpn/system');

  /// True when Android battery optimization is disabled for AMKT VPN.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final res =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's battery optimization exemption dialog/settings.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final res = await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's Hotspot / Tethering settings page.
  static Future<bool> openHotspotSettings() async {
    try {
      final res = await _channel.invokeMethod<bool>('openHotspotSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
