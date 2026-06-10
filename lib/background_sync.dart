import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ─── Notification service ────────────────────────────────────────────────────

const int    kNotifId   = 42;
const String kChannelId = 'forum_scanner_new_content';

final FlutterLocalNotificationsPlugin flutterLocalNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await flutterLocalNotifications.initialize(settings);

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

/// Show (or update) the persistent notification with current unread counts.
/// Call this after every sync that finds new content.
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
        number: unreadPosts + unreadPms, // badge count shown on launcher icon
        ongoing: false,
        autoCancel: true,
      ),
    ),
  );
}

/// Dismiss the notification (called when user opens the app).
Future<void> cancelNewContentNotification() async {
  await flutterLocalNotifications.cancel(kNotifId);
}
