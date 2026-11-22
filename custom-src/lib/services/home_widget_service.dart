import 'package:home_widget/home_widget.dart';

import '../models/vpn_server.dart';
import 'vpn_engine.dart';

/// Home-screen widget (Android) — status + Connect/Disconnect button.
///
/// How it works: the app pushes its status into the widget's data
/// (status, country, button label) and asks Android to redraw the
/// widget. The widget itself is native (see
/// android/app/src/main/kotlin/com/amkt/vpn/AmktVpnWidgetProvider.kt
/// + res/layout/amkt_vpn_widget.xml) — Flutter widgets cannot run on
/// the home screen.
///
/// HONEST LIMIT: tapping the widget button OPENS THE APP (via the
/// `amktvpn://toggle` deep link) and the app then toggles the VPN.
/// The widget cannot toggle the VPN while the app process is fully
/// dead without opening it — the VPN cores live in the Flutter
/// engine, and Android will not let a home-screen widget start a
/// VpnService from the background. In practice the app opens briefly
/// (often straight to the toggle action) and the user sees the
/// connect/disconnect happen there. The widget status refreshes
/// whenever the app updates it: on connect/disconnect, on server
/// selection change, and on app start.
class HomeWidgetService {
  static const String providerName = 'AmktVpnWidgetProvider';
  static const String toggleUri = 'amktvpn://toggle';

  /// Pushes the current VPN status into the widget and redraws it.
  /// Never throws.
  static Future<void> update(VpnState state, VpnServer? server) async {
    try {
      final connected = state == VpnState.connected;
      final connecting = state == VpnState.connecting;
      final status = connected
          ? 'Connected'
          : connecting
              ? 'Connecting…'
              : 'ချိတ်မထားပါ';
      final country = server == null
          ? ''
          : '${server.countryFlag} ${server.countryName}';
      final action = connected ? 'ဖြုတ်မယ်' : 'ချိတ်မယ်';
      await HomeWidget.saveWidgetData<String>('status', status);
      await HomeWidget.saveWidgetData<String>('country', country);
      await HomeWidget.saveWidgetData<String>('action', action);
      await HomeWidget.updateWidget(name: providerName);
    } catch (_) {
      // The widget is best-effort — never break the app for it.
    }
  }
}
