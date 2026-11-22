import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'app_store.dart';

/// Local notifications: expiry reminders + foreground FCM push notifications.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'amkt_reminders';
  static const String _channelName = 'သက်တမ်း သတိပေးချက်';
  static const String _channelDesc = 'ကီး သက်တမ်း ကုန်ခါနီး သတိပေးချက်';

  static const String pushChannelId = 'amkt_push';
  static const String _pushChannelName = 'သတင်းနှင့် အသိပေးချက်';
  static const String _pushChannelDesc = 'AMKT VPN မှ ပေးပို့သော အသိပေးချက်များ';

  static bool _initialized = false;
  static bool _available = false;

  static int _idFor(String subId) => 1000 + (subId.hashCode.abs() % 9000);

  /// Initialises the plugin and creates notification channels.
  /// NEVER throws — a failure only disables notifications; the app must
  /// always be able to open.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      const android = AndroidInitializationSettings('ic_vpn');
      const settings = InitializationSettings(android: android);
      await _plugin.initialize(settings: settings);
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          pushChannelId,
          _pushChannelName,
          description: _pushChannelDesc,
          importance: Importance.high,
        ),
      );
      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  /// Shows a foreground FCM push notification immediately. Never throws.
  static Future<void> showPushNotification({
    required String title,
    required String body,
  }) async {
    try {
      await init();
      if (!_available) return;
      final id = DateTime.now().millisecondsSinceEpoch.remainder(100000);
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            pushChannelId,
            _pushChannelName,
            channelDescription: _pushChannelDesc,
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_vpn',
          ),
        ),
      );
    } catch (_) {}
  }

  /// Android 13+: asks the user for the notification permission.
  static Future<bool> requestPermission() async {
    await init();
    if (!_available) return false;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    try {
      final granted = await android.requestNotificationsPermission() ?? false;
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Schedules "3 days before expiry" for one paid subscription.
  static Future<void> scheduleExpiryReminder({
    required String subId,
    required String label,
    required DateTime expireAt,
  }) async {
    await init();
    if (!_available) return;
    final reminderDay = DateTime(
        expireAt.year, expireAt.month, expireAt.day - 3, 9, 0);
    if (!reminderDay.isAfter(DateTime.now())) return;
    final when = tz.TZDateTime.from(reminderDay, tz.local);
    await _plugin.zonedSchedule(
      id: _idFor(subId),
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: 'AMKT VPN',
      body:
          '$label သက်တမ်း ၃ ရက်အတွင်း ကုန်ဆုံးမယ် — သက်တမ်းတိုးဖို့ @amktvpn ကို ဆက်သွယ်ပါ။',
    );
  }

  static Future<void> cancelReminder(String subId) async {
    await init();
    if (!_available) return;
    await _plugin.cancel(id: _idFor(subId));
  }

  static Future<void> refreshReminders(AppStore store) async {
    try {
      await init();
      for (final sub in store.subscriptions) {
        if (!sub.isPaid || sub.url.isEmpty) continue;
        final info = store.getUserInfo(sub.id);
        final expireAt = info?.expireAt;
        if (expireAt == null) {
          await cancelReminder(sub.id);
        } else {
          await scheduleExpiryReminder(
            subId: sub.id,
            label: sub.label.isEmpty ? 'ကီး' : sub.label,
            expireAt: expireAt,
          );
        }
      }
    } catch (_) {}
  }
}
