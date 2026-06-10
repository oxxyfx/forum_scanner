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
  await flutterLocalNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
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
}
