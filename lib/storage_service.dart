import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'forum_source.dart';

class StorageService {
  static const String _storageKey = 'saved_forum_sources';
  static const String _dismissedPostsKey = 'dismissed_forum_posts';

  /// Saves a list of forum sources to local device storage
  Future<void> saveSources(List<ForumSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final String encodedData = jsonEncode(
      sources.map((source) => source.toJson()).toList(),
    );
    await prefs.setString(_storageKey, encodedData);
  }

  /// Retrieves the saved list of forum sources from local device storage
  Future<List<ForumSource>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final String? rawJson = prefs.getString(_storageKey);

    if (rawJson == null || rawJson.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> decodedList = jsonDecode(rawJson);
      return decodedList.map((item) => ForumSource.fromJson(item)).toList();
    } catch (e) {
      print('Error parsing stored credentials: $e');
      return [];
    }
  }

  /// Loads the locally dismissed/read post keys.
  Future<Set<String>> loadDismissedPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_dismissedPostsKey)?.toSet() ?? <String>{};
  }

  /// Marks one forum item as locally dismissed/read.
  Future<void> dismissPostKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_dismissedPostsKey)?.toSet() ?? <String>{};
    current.add(key);
    await prefs.setStringList(_dismissedPostsKey, current.toList());
  }

  /// Clears all locally dismissed/read post keys.
  Future<void> clearDismissedPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dismissedPostsKey);
  }

  /// Saves a generic list of JSON-serialisable maps under [key].
  Future<void> saveJsonList(String key, List<Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(data));
  }

  /// Loads a list of maps previously saved with [saveJsonList]. Returns [] on miss or error.
  Future<List<Map<String, dynamic>>> loadJsonList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
