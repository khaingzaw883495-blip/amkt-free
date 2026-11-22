import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sing_box/sing_box.dart';

import '../models/vpn_server.dart';

/// Unified connection state across the sing-box core.
enum VpnState { disconnected, connecting, connected, error }

/// Unified traffic stats.
class VpnStats {
  final int downSpeed;
  final int upSpeed;
  final int downTotal;
  final int upTotal;
  final int durationSeconds;

  const VpnStats({
    this.downSpeed = 0,
    this.upSpeed = 0,
    this.downTotal = 0,
    this.upTotal = 0,
    this.durationSeconds = 0,
  });
}

/// The VPN engine: the sing-box core (VLESS / VMess / Trojan /
/// Shadowsocks). Only one tunnel runs at a time.
///
/// v1.0.7 — the OpenVPN core is GONE (the .ovpn import was removed, so
/// no OpenVPN server can be created any more; VpnServer.canConnect
/// refuses OpenVPN servers). The 5-hour auto-disconnect is GONE too —
/// it is replaced by the time-credit system (TimeCreditService), which
/// counts down while connected and disconnects at 0:00:00.
///
/// Auto-reconnect (v1.0.2): two layers.
///  1. Native: `SingBoxSettings.autoReconnectOnDisconnect` is turned on
///     at init — the sing-box service is START_STICKY and reconnects
///     after network changes / failures on its own.
///  2. Dart watchdog (this class): when the tunnel drops unexpectedly
///     while the user still wants to be connected, it retries the last
///     server (max 3 attempts, 5 s apart, then it stops and reports an
///     error instead of looping forever). Manual Disconnect clears the
///     intent, so it never fights the user.
/// Kill switch (v1.0.2): `SingBoxSettings.killSwitch` is applied from
/// the stored toggle. On Android the plugin can only enforce
/// `strict_route` while the tunnel runs; full blocking (traffic
/// blocked while the VPN is off) needs the user to enable
/// "Block connections without VPN" in Android system settings — the
/// Settings screen opens that page for them.
class VpnEngine {
  static final VpnEngine instance = VpnEngine._();
  VpnEngine._();

  VpnServer? currentServer;
  String? lastError;

  final _stateCtrl = StreamController<VpnState>.broadcast();
  final _statsCtrl = StreamController<VpnStats>.broadcast();

  Stream<VpnState> get stateStream => _stateCtrl.stream;
  Stream<VpnStats> get statsStream => _statsCtrl.stream;

  VpnState _state = VpnState.disconnected;
  VpnState get state => _state;
  bool get isConnected => _state == VpnState.connected;

  bool _initialized = false;
  DateTime? _connectedSince;

  /// True when the user connected and has not tapped Disconnect since.
  /// Drives auto-reconnect; cleared only by a manual disconnect.
  bool _wantConnected = false;
  VpnServer? _lastServer;
  int _reconnectAttempts = 0;
  bool _reconnectPending = false;

  void _setState(VpnState s, {String? error}) {
    _state = s;
    if (error != null) lastError = error;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  void _emitStats(VpnStats s) {
    if (!_statsCtrl.isClosed) _statsCtrl.add(s);
  }

  Future<void> init({bool killSwitch = false}) async {
    if (_initialized) return;
    await SingBox.instance.initialize(const SingBoxOptions(
      android: SingBoxAndroidOptions(
        notificationTitle: 'AMKT VPN',
        notificationIcon: 'ic_vpn',
        showTrafficInNotification: true,
        stopActionTitle: 'Disconnect',
      ),
    ));
    // v1.0.2 — auto-reconnect: let the native service restart the
    // tunnel itself after network changes / failures (START_STICKY).
    // Kill switch: apply the stored toggle (see applyKillSwitch).
    await SingBox.instance
        .updateSetting(SingBoxSettings.keyAutoReconnectOnDisconnect, true)
        .catchError((_) => false);
    await SingBox.instance
        .updateSetting(SingBoxSettings.keyKillSwitch, killSwitch)
        .catchError((_) => false);
    // v1.0.2 — network-change watchdog (Dart side, see below). The
    // engine is a singleton that lives for the app's whole life, so
    // the subscription is intentionally never cancelled.
    Connectivity().onConnectivityChanged.listen((results) {
      if (results.contains(ConnectivityResult.none)) return;
      if (_wantConnected && _state == VpnState.disconnected) {
        _scheduleReconnect();
      }
    });
    SingBox.instance.watchConnectionStatus().listen((status) {
      if (status.isActive) {
        _connectedSince ??= DateTime.now();
        _reconnectAttempts = 0;
        _setState(VpnState.connected);
      } else if (_state == VpnState.connected) {
        _setState(VpnState.disconnected);
        _onUnexpectedDrop();
      }
    });
    SingBox.instance.watchConnectionStats().listen((s) {
      _emitStats(VpnStats(
        downSpeed: s.downloadSpeed.toInt(),
        upSpeed: s.uploadSpeed.toInt(),
        downTotal: s.downloadTotal.toInt(),
        upTotal: s.uploadTotal.toInt(),
        durationSeconds: _durationSeconds(s.duration),
      ));
    });
    SingBox.instance.watchConnectionState().listen((st) {
      final err = st.error;
      if (err != null && _state == VpnState.connecting) {
        _setState(VpnState.error, error: err.toString());
      }
    });
    _initialized = true;
  }

  /// Applies the kill-switch toggle to the sing-box service.
  /// The plugin can only enforce `strict_route` while the tunnel runs;
  /// full blocking while the VPN is off needs the Android system
  /// setting "Block connections without VPN" (opened from Settings via
  /// `SingBox.instance.openVpnSettings()`).
  Future<void> applyKillSwitch(bool value) async {
    await SingBox.instance
        .updateSetting(SingBoxSettings.keyKillSwitch, value)
        .catchError((_) => false);
  }

  /// Opens Android's VPN settings page, where the user turns on
  /// "Always-on VPN" + "Block connections without VPN" for this app.
  Future<void> openSystemVpnSettings() async {
    await SingBox.instance.openVpnSettings().catchError((_) {});
  }

  // ------------------------------------------------- auto-reconnect watchdog

  void _onUnexpectedDrop() {
    if (!_wantConnected) return;
    _scheduleReconnect();
  }

  /// Retries the last server after a 5 s pause, at most 3 attempts in
  /// total; then it stops and reports an error instead of looping
  /// forever. A manual Disconnect clears `_wantConnected`, so this
  /// never fights the user. A successful connect resets the counter.
  void _scheduleReconnect() {
    if (!_wantConnected || _lastServer == null) return;
    if (_reconnectAttempts >= 3 || _reconnectPending) return;
    _reconnectPending = true;
    Future.delayed(const Duration(seconds: 5), () async {
      _reconnectPending = false;
      if (!_wantConnected || _lastServer == null) return;
      if (_state != VpnState.disconnected && _state != VpnState.error) {
        return;
      }
      _reconnectAttempts++;
      try {
        await connect(_lastServer!, isRetry: true);
      } catch (_) {
        // connect() already reported the error state. When the
        // attempts run out, stop trying and say so plainly.
        if (_reconnectAttempts >= 3) {
          _wantConnected = false;
          _setState(VpnState.error,
              error: 'လိုင်း ပြုတ်သွားလို့ ပြန်ချိတ်မရပါ — Connect ပြန်နှိပ်ပါ');
        }
      }
    });
  }

  int _durationSeconds(dynamic d) {
    if (d is Duration) return d.inSeconds;
    if (d is num) return d.toInt();
    return _connectedSince == null
        ? 0
        : DateTime.now().difference(_connectedSince!).inSeconds;
  }

  // ------------------------------------------------------------- connect API

  /// A watchdog retry keeps the last server — it is only set on a fresh
  /// (non-retry) connect.
  Future<void> connect(VpnServer server, {bool isRetry = false}) async {
    if (!server.canConnect) {
      throw UnsupportedError(
          '${server.protocol.label} ချိတ်ဆက်မှု ဒီ version မှာ မရသေးပါ');
    }
    // The user wants this connection — remember it for auto-reconnect.
    _wantConnected = true;
    _lastServer = server;
    // A manual connect resets the retry counter; a watchdog retry must
    // NOT reset it, or the 3-attempt cap would never be reached.
    if (!isRetry) _reconnectAttempts = 0;
    await _stopCurrent().catchError((_) {});
    currentServer = server;
    _connectedSince = null;
    _setState(VpnState.connecting);
    try {
      await SingBox.instance.connect(server.connectInput);
    } catch (e) {
      currentServer = null;
      _setState(VpnState.error, error: e.toString());
      rethrow;
    }
  }

  /// Manual disconnect: clears the auto-reconnect intent first, so the
  /// watchdog never re-connects after the user tapped Disconnect.
  Future<void> disconnect() async {
    _wantConnected = false;
    _lastServer = null;
    _reconnectAttempts = 0;
    await _stopCurrent();
  }

  /// Stops the running tunnel without touching the reconnect intent.
  Future<void> _stopCurrent() async {
    await SingBox.instance.disconnect().catchError((_) {});
    currentServer = null;
    _connectedSince = null;
    _emitStats(const VpnStats());
    _setState(VpnState.disconnected);
  }
}
