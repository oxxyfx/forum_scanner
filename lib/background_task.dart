import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'background_sync.dart';
import 'smf_service.dart';
import 'storage_service.dart';

/// Identifiers shared between Dart (registerPeriodicTask) and the native
/// iOS side (AppDelegate.swift / Info.plist BGTaskSchedulerPermittedIdentifiers).
const String kBackgroundTaskUniqueName = 'forumScannerSync';
const String kBackgroundTaskName = 'com.example.nghobbies.forum_scanner.sync';

/// How often we *ask* the OS to run the sync. Android honours this closely;
/// iOS treats it as a minimum and may run it less often depending on
/// battery, network and usage patterns.
const Duration kBackgroundTaskFrequency = Duration(minutes: 20);

/// Entry point for background work. Runs in its own isolate, so it cannot
/// access any app state — everything needed must be reloaded from disk.
/// Must remain a top-level function and keep the @pragma annotation.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Required before touching any plugin (SharedPreferences,
      // flutter_local_notifications, etc.) from this headless background
      // isolate — without it, plugin channel calls can throw and get
      // swallowed by the catch below, making the task silently no-op.
      WidgetsFlutterBinding.ensureInitialized();
      await checkForNewContentInBackground();
    } catch (_) {
      // A failed background check shouldn't crash retries forever —
      // the next scheduled run will simply try again.
    }
    return Future.value(true);
  });
}

/// Logs into each configured forum, counts unread topics/PMs (using the
/// same "read" bookkeeping the foreground UI uses), and updates the
/// notification badge accordingly. Does NOT touch the cached post/PM/
/// calendar lists — that merge logic lives in main.dart and runs when the
/// app is foregrounded.
Future<void> checkForNewContentInBackground() async {
  final storage = StorageService();
  final sources = await storage.loadSources();
  final activeSources = sources.where((s) => s.baseUrl.trim().isNotEmpty).toList();
  if (activeSources.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();

  // Maps post key → sortStamp at the time it was marked read (mirrors
  // _readPostStamps in main.dart). A topic only counts as unread if it was
  // never read, or its current sortStamp is newer than the stored one.
  Map<String, int> readPostStamps = {};
  final rawPostStamps = prefs.getString('read_post_stamps');
  if (rawPostStamps != null && rawPostStamps.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawPostStamps) as Map;
      readPostStamps = decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {}
  }

  Map<String, int> readPmStamps = {};
  final rawPmStamps = prefs.getString('read_pm_stamps');
  if (rawPmStamps != null && rawPmStamps.isNotEmpty) {
    try {
      final decoded = jsonDecode(rawPmStamps) as Map;
      readPmStamps = decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {}
  }

  int unreadPosts = 0;
  int unreadPms = 0;

  for (final source in activeSources) {
    try {
      final service = SmfService(source: source);
      final loggedIn = await service.login();
      if (!loggedIn) continue;

      // Count unread topics (mirrors _parsePosts key logic in main.dart).
      final unreadData = await service.fetchUnreadTopics();
      final topics = (unreadData?['topics'] as List?) ?? const [];
      for (final raw in topics) {
        if (raw is! Map) continue;
        final topic = Map<String, dynamic>.from(raw);
        final tid = (topic['tid'] ?? topic['topic']?['tid'] ?? topic['slug'] ?? topic['title'] ?? '').toString();
        if (tid.trim().isEmpty) continue;
        final key = '${source.id}:$tid';

        final createdStamp = _parseForumStamp(topic['timestamp'] ?? topic['timestampISO'] ?? topic['createdAt']);
        final lastReplyStamp = _parseForumStamp(
          topic['lastposttime'] ?? topic['lastposttimeISO'] ?? topic['lastPostTime'] ?? topic['lastpost']?['timestamp'],
        );
        final sortStamp = lastReplyStamp != 0 ? lastReplyStamp : createdStamp;

        final readStamp = readPostStamps[key];
        if (readStamp == null || sortStamp > readStamp) unreadPosts++;
      }

      // Count unread PMs (mirrors _parsePrivateMessages key logic in main.dart).
      final pmData = await service.fetchPrivateMessages();
      for (final raw in pmData) {
        final item = Map<String, dynamic>.from(raw);
        final body = (item['body'] ?? item['content'] ?? item['preview'] ?? '').toString().trim();
        if (body.isEmpty || body == 'No messages in this chat') continue;

        final sender = (item['sender'] ?? item['from'] ?? item['username'] ?? 'Unknown').toString();
        final title = (item['title'] ?? item['subject'] ?? 'Private Message').toString();
        final roomId = (item['roomId'] ?? item['id'] ?? item['chatId'] ?? '').toString();
        final keyBase = roomId.isNotEmpty ? roomId : '$sender|$title';
        final key = '${source.id}:$keyBase';
        final stamp = int.tryParse((item['timestamp'] ?? item['time'] ?? 0).toString()) ?? 0;

        final lastRead = readPmStamps[key];
        if (lastRead == null || stamp > lastRead) unreadPms++;
      }
    } catch (_) {
      // Ignore per-source failures (offline, login error, etc.) and
      // continue with the other forums.
    }
  }

  await initNotifications();
  await showNewContentNotification(unreadPosts, unreadPms);
}

/// Registers the periodic background task. Safe to call every app launch —
/// Workmanager replaces any existing task with the same unique name.
Future<void> registerBackgroundSync() async {
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    kBackgroundTaskUniqueName,
    kBackgroundTaskName,
    frequency: kBackgroundTaskFrequency,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
  );
}

/// Mirrors _parseForumDate in main.dart. Kept as a local copy to avoid a
/// circular import (main.dart already imports this file).
DateTime? _parseForumDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;

  int? numeric;

  if (value is int) {
    numeric = value;
  } else if (value is double) {
    numeric = value.round();
  } else {
    final text = value.toString().trim();
    if (text.isEmpty) return null;

    numeric = int.tryParse(text);
    if (numeric == null) {
      return DateTime.tryParse(text);
    }
  }

  // 10 digits = seconds, 13 digits = milliseconds
  if (numeric.abs() < 100000000000) {
    return DateTime.fromMillisecondsSinceEpoch(numeric * 1000);
  }

  return DateTime.fromMillisecondsSinceEpoch(numeric);
}

/// Mirrors _parseForumStamp in main.dart.
int _parseForumStamp(dynamic value) {
  final parsed = _parseForumDate(value);
  return parsed?.millisecondsSinceEpoch ?? 0;
}
