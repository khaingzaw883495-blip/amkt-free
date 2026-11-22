import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Time credit (Add Time) system — v1.0.7, REPLACES the 5-hour
/// auto-disconnect (removed from VpnEngine).
///
/// Free users get a 6-hour time credit, shown as "Time Left" on the VPN
/// tab. It counts down while the VPN is connected. When it runs out,
/// the VPN disconnects and the user taps "Add Time" (before connecting)
/// to get +9 hours — at most 2 extends per day (v1.0.7 phone-test
/// fix 2026-11-17 "12 အစား 9 ... စုစုပေါင်း 24" — 2/day × 9h =
/// 24h total, superseding the earlier 2/day × 12h). Buyers (a valid no-ads
/// code) have unlimited time: no countdown, no Time Left display, no
/// limit — the UI never starts this service for them.
///
/// Storage (SharedPreferences, local only):
/// - remaining seconds (6 hours granted on first use)
/// - extends used today + the date they belong to (resets daily)
///
/// Honest limits (same as the old 5-hour timer): the countdown lives in
/// the app process — if Android kills the app, the timer dies with it
/// and the credit stops counting until the app runs again. The credit
/// is only spent while the app is alive and connected.
class TimeCreditService {
  /// Free credit granted on first use.
  static const int initialCreditSeconds = 6 * 3600; // 6 hours

  /// Seconds added by one Add Time extend.
  static const int extendSeconds = 9 * 3600; // +9 hours

  /// Max extends per day.
  static const int maxExtendsPerDay = 2;

  static const _kRemaining = 'time_credit_remaining_seconds';
  static const _kExtendsDate = 'time_credit_extends_date';
  static const _kExtendsUsed = 'time_credit_extends_used';

  final SharedPreferences _prefs;
  TimeCreditService(this._prefs);

  static Future<TimeCreditService> load() async {
    final prefs = await SharedPreferences.getInstance();
    final svc = TimeCreditService(prefs);
    // Grant the first 6 hours on first use (persisted so it survives
    // restarts; later extends only add on top of what is left).
    if (prefs.getInt(_kRemaining) == null) {
      await prefs.setInt(_kRemaining, initialCreditSeconds);
    }
    return svc;
  }

  final _remainingCtrl = StreamController<int>.broadcast();

  /// Remaining credit in seconds. Emits on every tick and every extend,
  /// so the UI can show a live "Time Left" countdown.
  Stream<int> get remainingStream => _remainingCtrl.stream;

  int get remainingSeconds => _prefs.getInt(_kRemaining) ?? initialCreditSeconds;

  Timer? _timer;

  /// "HH:MM:SS" (always with hours, e.g. "06:00:00").
  static String format(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------- daily extends

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int _extendsUsedToday() {
    if (_prefs.getString(_kExtendsDate) != _todayKey()) return 0;
    return _prefs.getInt(_kExtendsUsed) ?? 0;
  }

  /// Extends left today (0..2). Resets automatically each new day.
  int get extendsLeftToday {
    final left = maxExtendsPerDay - _extendsUsedToday();
    return left < 0 ? 0 : left;
  }

  bool get canExtend => extendsLeftToday > 0;

  /// Adds +9 hours and uses up one of today's extends. Returns false
  /// (and adds nothing) when no extends are left today.
  Future<bool> extend() async {
    if (!canExtend) return false;
    final used = _extendsUsedToday();
    await _prefs.setString(_kExtendsDate, _todayKey());
    await _prefs.setInt(_kExtendsUsed, used + 1);
    final remaining = remainingSeconds + extendSeconds;
    await _prefs.setInt(_kRemaining, remaining);
    if (!_remainingCtrl.isClosed) _remainingCtrl.add(remaining);
    return true;
  }

  // ------------------------------------------------------------- countdown

  /// Starts the 1-second countdown (call when a free connection comes
  /// up). When the credit hits 0 the timer stops and [onExpired] runs
  /// (the caller disconnects the VPN and shows the Add Time prompt).
  /// Safe to call when the credit is already 0 — [onExpired] runs at
  /// once and no timer is started.
  void startCountdown({required void Function() onExpired}) {
    stopCountdown();
    if (remainingSeconds <= 0) {
      // No credit left — expire immediately, never start a timer.
      Future.microtask(onExpired);
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final remaining = remainingSeconds - 1;
      await _prefs.setInt(
          _kRemaining, remaining < 0 ? 0 : remaining);
      if (!_remainingCtrl.isClosed) {
        _remainingCtrl.add(remaining < 0 ? 0 : remaining);
      }
      if (remaining <= 0) {
        stopCountdown();
        onExpired();
      }
    });
  }

  /// Stops the countdown (call when the VPN disconnects).
  void stopCountdown() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stopCountdown();
    _remainingCtrl.close();
  }
}
