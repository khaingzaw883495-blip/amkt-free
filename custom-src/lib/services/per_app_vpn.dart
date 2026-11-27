import 'package:installed_apps/installed_apps.dart';
import 'package:sing_box/sing_box.dart';

import 'app_store.dart';

/// Per-app VPN (split tunnel, v1.0.5).
///
/// Mechanism (all in the sing-box plugin, no custom native code):
/// the ticked package names are written to sing-box's routing rules as
/// `proxyApps`, which the plugin translates to TUN `include_package`
/// (Android `VpnService.Builder.addAllowedApplication`) — only those
/// apps' traffic enters the tunnel; every other app goes direct.
/// An EMPTY list means "no selection": every app uses the VPN, exactly
/// as before (the plugin documents this, and the native service treats
/// an empty include list as "capture everything").
///
/// What it does and does NOT do (honest limits):
/// - Applies ONLY to sing-box servers (VLESS / VMess / Trojan /
///   Shadowsocks) — v1.0.7 removed OpenVPN, so there is no other
///   core any more.
/// - The selection is applied at connect time (the plugin reads the
///   stored rules when building the tunnel config) AND live: changing
///   the selection while connected reloads the running tunnel
///   (`reloadOnRulesChange` is on by default in the plugin), so the
///   new selection takes effect immediately — the tunnel restarts
///   briefly when it reloads.
/// - Android only. The app list comes from PackageManager
///   (`QUERY_ALL_PACKAGES`, declared by the installed_apps plugin).
///   System apps and non-launchable apps are hidden from the list.
/// - The VPN app's own traffic always goes direct anyway (the
///   VpnService's own UID is excluded by Android), which is also why
///   code validation and list refreshes keep working before connecting.
/// - A ticked app that is not installed (any more) is silently
///   ignored by the native service; the stored selection keeps it,
///   so it works again if the app is reinstalled.
class PerAppVpnService {
  PerAppVpnService._();

  /// The phone's installed launchable apps (non-system), with icons,
  /// sorted by name. Returns an empty list when the query fails — the
  /// UI treats that as "could not load" and offers a retry.
  /// v1.0.7 — ALL apps are shown, including AMKT itself (the v1.0.6
  /// filter that hid com.amkt.vpn is removed, on her word). AMKT never
  /// needs selecting (Android always routes the VpnService's own
  /// traffic direct), but she wants it listed anyway.
  static Future<List<AppInfo>> loadApps({
    bool includeSystemApps = false,
  }) async {
    return InstalledApps.getInstalledApps(
      excludeSystemApps: !includeSystemApps,
      excludeNonLaunchableApps: true,
      withIcon: true,
      detectPlatformType: false,
    );
  }

  /// Pushes the stored selection into sing-box's routing rules.
  /// Best-effort: a failure here never throws (the selection stays
  /// saved in AppStore and is re-applied on the next open / connect).
  static Future<void> applyStoredSelection(AppStore store) async {
    try {
      await SingBox.instance.setProxyApps(store.perAppPackages.toList());
    } catch (_) {
      // Stored in AppStore already; the next apply heals it.
    }
  }

  /// Saves a new selection AND pushes it to sing-box. Call this on
  /// every toggle, so the stored rules are always current.
  static Future<void> saveSelection(AppStore store, Set<String> pkgs) async {
    await store.setPerAppPackages(pkgs);
    await applyStoredSelection(store);
  }
}
