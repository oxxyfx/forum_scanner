import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─── Notification service ────────────────────────────────────────────────────

const int    kNotifId   = 42;
const String kChannelId = 'forum_scanner_new_content';

final FlutterLocalNotificationsPlugin flutterLocalNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: false,
  );
  const settings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await flutterLocalNotifications.initialize(settings);

  // Android-only: create the notification channel
  const channel = AndroidNotificationChannel(
    kChannelId,
    'New content',
    description: 'Alerts when new forum posts or PMs arrive',
    importance: Importance.defaultImportance,
    showBadge: true,
  );
  final androidPlugin = flutterLocalNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(channel);

  // Android 13+ (API 33) requires runtime permission for notifications —
  // without this, both the foreground "new content" notification and the
  // badge/number it carries are silently dropped, even though the manifest
  // declares POST_NOTIFICATIONS. Safe to call repeatedly; it's a no-op once
  // granted (or denied) and on pre-13 devices.
  await androidPlugin?.requestNotificationsPermission();
}

/// Show (or update) the notification with current unread counts.
Future<void> showNewContentNotification(int unreadPosts, int unreadPms) async {
  if (unreadPosts == 0 && unreadPms == 0) {
    await cancelNewContentNotification();
    return;
  }

  final parts = <String>[];
  if (unreadPosts > 0) parts.add('$unreadPosts unread post${unreadPosts > 1 ? 's' : ''}');
  if (unreadPms > 0)   parts.add('$unreadPms unread PM${unreadPms > 1 ? 's' : ''}');

  await flutterLocalNotifications.show(
    kNotifId,
    'Forum Scanner',
    parts.join(' • '),
    NotificationDetails(
      android: AndroidNotificationDetails(
        kChannelId,
        'New content',
        channelDescription: 'Alerts when new forum posts or PMs arrive',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        number: unreadPosts + unreadPms,
        ongoing: false,
        autoCancel: true,
      ),
      iOS: DarwinNotificationDetails(
        badgeNumber: unreadPosts + unreadPms,
        presentAlert: true,
        presentBadge: true,
        presentSound: false,
      ),
    ),
  );
}

/// Dismiss the notification (called when user opens the app).
Future<void> cancelNewContentNotification() async {
  await flutterLocalNotifications.cancel(kNotifId);

  // iOS: cancelling a notification does NOT reset the home-screen app icon
  // badge — the badge is independent OS state set by the last notification's
  // badgeNumber. Push a silent, alert-free notification with badgeNumber: 0
  // to clear it, then remove it from the notification center immediately.
  await flutterLocalNotifications.show(
    kNotifId,
    '',
    '',
    const NotificationDetails(
      iOS: DarwinNotificationDetails(
        badgeNumber: 0,
        presentAlert: false,
        presentBanner: false,
        presentList: false,
        presentBadge: true,
        presentSound: false,
      ),
    ),
  );
  await flutterLocalNotifications.cancel(kNotifId);
}
