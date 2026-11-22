import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'notifications.dart';

/// Top-level background handler required by Firebase Messaging.
/// Runs in its own isolate when a push arrives while the app is killed
/// or in the background. Notification payloads are displayed by Android
/// automatically; this handler ensures background delivery never throws.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
}

/// Firebase Cloud Messaging (FCM) push notification service (v1.0.10).
///
/// Subscribes every device to the `all` topic so announcements can be sent
/// directly from the Firebase Console (`amkt-vpn` project) to all users.
/// Foreground messages are displayed via [NotificationService.showPushNotification].
/// Best-effort: NEVER throws so startup can never be blocked.
class FcmService {
  FcmService._();

  static bool _initialized = false;

  static Future<void> init({bool isPaid = false}) async {
    if (_initialized) return;
    _initialized = true;
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      final messaging = FirebaseMessaging.instance;

      // Best-effort topic subscriptions for Firebase Console campaigns.
      unawaited(messaging.subscribeToTopic('all').catchError((_) {}));
      if (isPaid) {
        unawaited(messaging.subscribeToTopic('vip').catchError((_) {}));
        unawaited(messaging.unsubscribeFromTopic('free').catchError((_) {}));
      } else {
        unawaited(messaging.subscribeToTopic('free').catchError((_) {}));
        unawaited(messaging.unsubscribeFromTopic('vip').catchError((_) {}));
      }

      // Show foreground notifications when the app is open.
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notif = message.notification;
        final title = notif?.title?.trim() ??
            (message.data['title'] as String?)?.trim() ??
            '';
        final body = notif?.body?.trim() ??
            (message.data['body'] as String?)?.trim() ??
            '';
        // Guard against empty dismissal broadcasts.
        if (title.isEmpty && body.isEmpty) return;
        unawaited(
          NotificationService.showPushNotification(
            title: title.isEmpty ? 'AMKT VPN' : title,
            body: body,
          ),
        );
      });
    } catch (_) {
      // Never block app startup if FCM fails.
    }
  }

  /// Syncs the user's `vip` / `free` topic after redeeming a VIP code.
  static Future<void> syncTierTopic({required bool isPaid}) async {
    try {
      final messaging = FirebaseMessaging.instance;
      if (isPaid) {
        await messaging.subscribeToTopic('vip');
        await messaging.unsubscribeFromTopic('free');
      } else {
        await messaging.subscribeToTopic('free');
        await messaging.unsubscribeFromTopic('vip');
      }
    } catch (_) {}
  }
}
