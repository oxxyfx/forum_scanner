import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'background_sync.dart';
import 'background_task.dart';
import 'forum_source.dart';
import 'smf_service.dart';
import 'storage_service.dart';


String _decodeHtmlText(String value) {
  if (value.trim().isEmpty) return value;
  return html_parser.parseFragment(value).text?.trim() ?? value;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initNotifications();
  await registerBackgroundSync();
  runApp(const ForumAggregatorApp());
}

class ForumAggregatorApp extends StatelessWidget {
  const ForumAggregatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forum Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ForumAggregatorHome(),
    );
  }
}

class ForumAggregatorHome extends StatefulWidget {
  const ForumAggregatorHome({super.key});

  @override
  State<ForumAggregatorHome> createState() => _ForumAggregatorHomeState();
}

class _ForumAggregatorHomeState extends State<ForumAggregatorHome>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final StorageService _storage = StorageService();

  List<ForumSource> _sources = [];
  List<_ForumPost> _posts = [];
  List<_ForumCalendarEntry> _calendarEntries = [];
  List<_ForumPrivateMessage> _privateMessages = [];
  Set<String> _readPostKeys = <String>{};
  // Maps pm.key → sortStamp when user last read it.
  // A PM is "unread" if its current sortStamp is greater than the stored stamp.
  Map<String, int> _readPmStamps = {};
  Map<String, int> _hiddenPmMap = {};
  bool _showHiddenPms = false;
  bool _showReadPosts = false;
  String _postSearchQuery = '';
  final TextEditingController _postSearchController = TextEditingController();

  late final TabController _tabController;
  bool _isLoading = false;
  String _status = 'Ready';
  String _calendarView = 'list'; // 'list' or 'calendar'
  DateTime _calendarDisplayMonth = DateTime(DateTime.now().year, DateTime.now().month);
  final TransformationController _calendarTransformController = TransformationController();
  double _calendarZoom = 1.0;
  int _calendarActivePointers = 0;
  bool _calendarMultiTouch = false;

  DateTime? _lastSyncTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() {}); });
    _loadEverything();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _calendarTransformController.dispose();
    _postSearchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Cancel any pending notification — user is now in the app
      cancelNewContentNotification();
      // Auto-sync if last sync was more than 30 minutes ago (or never)
      final now = DateTime.now();
      if (_lastSyncTime == null ||
          now.difference(_lastSyncTime!) > const Duration(minutes: 30)) {
        if (!_isLoading) _syncAll();
      }
    }
  }

  Future<void> _loadEverything() async {
    final sources = await _storage.loadSources();
    final readKeys = await _loadReadPostKeys();
    final readPmStamps = await _loadReadPmStamps();
    final hiddenPmMap = await _loadHiddenPmMap();

    if (!mounted) return;
    // Set sources first so deserializers can look them up
    setState(() {
      _sources = _normalizeSources(sources);
      _readPostKeys = readKeys;
      _readPmStamps = readPmStamps;
      _hiddenPmMap = hiddenPmMap;
      _status = sources.isEmpty ? 'Open setup to add forum accounts.' : 'Loaded ${sources.length} forum account(s).';
    });

    // Load cached data and show immediately
    final cachedPosts     = await _storage.loadJsonList('cached_posts');
    final cachedPms       = await _storage.loadJsonList('cached_pms');
    final cachedCalendar  = await _storage.loadJsonList('cached_calendar');

    if (!mounted) return;
    final posts    = cachedPosts.map(_postFromJson).whereType<_ForumPost>().toList()..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));
    final pms      = cachedPms.map(_pmFromJson).whereType<_ForumPrivateMessage>().toList()..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));
    final calendar = cachedCalendar.map(_calendarFromJson).whereType<_ForumCalendarEntry>().toList()..sort((a, b) => a.start.compareTo(b.start));

    if (posts.isNotEmpty || pms.isNotEmpty || calendar.isNotEmpty) {
      setState(() {
        _posts = posts;
        _privateMessages = pms;
        _calendarEntries = calendar;
        _status = 'Showing cached data — tap sync to refresh.';
      });
    }
  }

  // ── Serialization helpers ──────────────────────────────────────────────────

  ForumSource? _findSource(String id) {
    try { return _sources.firstWhere((s) => s.id == id); } catch (_) { return null; }
  }

  Map<String, dynamic> _postToJson(_ForumPost p) => {
    'sourceId': p.source.id,
    'raw': p.raw,
    'key': p.key,
    'title': p.title,
    'author': p.author,
    'sortStamp': p.sortStamp,
    'createdStamp': p.createdStamp,
    'lastReplyStamp': p.lastReplyStamp,
  };

  _ForumPost? _postFromJson(Map<String, dynamic> j) {
    final source = _findSource((j['sourceId'] ?? '').toString());
    if (source == null) return null;
    return _ForumPost(
      source: source,
      raw: Map<String, dynamic>.from((j['raw'] as Map?) ?? {}),
      key: (j['key'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      author: (j['author'] ?? '').toString(),
      sortStamp: (j['sortStamp'] as num?)?.toInt() ?? 0,
      createdStamp: (j['createdStamp'] as num?)?.toInt() ?? 0,
      lastReplyStamp: (j['lastReplyStamp'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> _pmToJson(_ForumPrivateMessage p) => {
    'sourceId': p.source.id,
    'key': p.key,
    'roomId': p.roomId,
    'title': p.title,
    'sender': p.sender,
    'body': p.body,
    'sortStamp': p.sortStamp,
  };

  _ForumPrivateMessage? _pmFromJson(Map<String, dynamic> j) {
    final source = _findSource((j['sourceId'] ?? '').toString());
    if (source == null) return null;
    return _ForumPrivateMessage(
      source: source,
      key: (j['key'] ?? '').toString(),
      roomId: (j['roomId'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      sender: (j['sender'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      sortStamp: (j['sortStamp'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> _calendarToJson(_ForumCalendarEntry e) => {
    'key': e.key,
    'sourceId': e.source.id,
    'title': e.title,
    'description': e.description,
    'start': e.start.toIso8601String(),
    'end': e.end?.toIso8601String(),
    'url': e.url,
  };

  _ForumCalendarEntry? _calendarFromJson(Map<String, dynamic> j) {
    final source = _findSource((j['sourceId'] ?? '').toString());
    if (source == null) return null;
    final start = DateTime.tryParse((j['start'] ?? '').toString());
    if (start == null) return null;
    final key = (j['key'] ?? '').toString();
    if (key.isEmpty) return null;
    // Drop old-format keys ("sourceId:cal:pid" with 3 segments, last numeric).
    // New format is "sourceId:cal:pid:startMs" (4 segments) so recurring-event
    // instances with the same pid but different dates get unique keys.
    final parts = key.split(':');
    if (parts.length == 3 && int.tryParse(parts[2]) != null) return null;
    return _ForumCalendarEntry(
      source: source,
      key: key,
      title: (j['title'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      start: start,
      end: j['end'] != null ? DateTime.tryParse(j['end'].toString()) : null,
      url: (j['url'] ?? '').toString(),
    );
  }

  Future<void> _saveCache() async {
    await Future.wait([
      _storage.saveJsonList('cached_posts', _posts.map(_postToJson).toList()),
      _storage.saveJsonList('cached_pms', _privateMessages.map(_pmToJson).toList()),
      _storage.saveJsonList('cached_calendar', _calendarEntries.map(_calendarToJson).toList()),
    ]);
  }

  List<ForumSource> _normalizeSources(List<ForumSource> saved) {
    final colors = <int>[
      Colors.blue.toARGB32(),
      Colors.green.toARGB32(),
      Colors.deepOrange.toARGB32(),
    ];

    final list = <ForumSource>[];
    for (int i = 0; i < 3; i++) {
      if (i < saved.length) {
        final s = saved[i];
        list.add(
          ForumSource(
            id: s.id.isEmpty ? 'forum_${i + 1}' : s.id,
            name: s.name.isEmpty ? 'Forum ${i + 1}' : s.name,
            baseUrl: s.baseUrl,
            username: s.username,
            password: s.password,
            colorValue: s.colorValue == 0 ? colors[i] : s.colorValue,
          ),
        );
      } else {
        list.add(
          ForumSource(
            id: 'forum_${i + 1}',
            name: 'Forum ${i + 1}',
            baseUrl: '',
            username: '',
            password: '',
            colorValue: colors[i],
          ),
        );
      }
    }
    return list;
  }

  String _formatPmTimestamp(int stamp) {
    if (stamp <= 0) return 'Unknown time';
    return _formatDateTime(DateTime.fromMillisecondsSinceEpoch(stamp));
  }


  Future<Set<String>> _loadReadPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('read_post_keys')?.toSet() ?? <String>{};
  }

  Future<Map<String, int>> _loadReadPmStamps() async {
    final prefs = await SharedPreferences.getInstance();
    // New format: JSON map of key→stamp
    final raw = prefs.getString('read_pm_stamps');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map;
        return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
      } catch (_) {}
    }
    // Migrate from old Set format
    final oldKeys = prefs.getStringList('read_pm_keys') ?? [];
    return {for (final k in oldKeys) k: 0};
  }

  Future<void> _saveReadPmStamps() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('read_pm_stamps', jsonEncode(_readPmStamps));
  }

  Future<Map<String, int>> _loadHiddenPmMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('hidden_pm_map');
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveHiddenPmMap() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hidden_pm_map', jsonEncode(_hiddenPmMap));
  }

  Future<void> _toggleHidePm(_ForumPrivateMessage pm) async {
    if (_hiddenPmMap.containsKey(pm.key)) {
      _hiddenPmMap.remove(pm.key);
    } else {
      _hiddenPmMap[pm.key] = pm.sortStamp;
    }
    await _saveHiddenPmMap();
    if (!mounted) return;
    setState(() {});
  }


  Future<void> _saveReadPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('read_post_keys', _readPostKeys.toList());
  }

  Future<void> _markPostRead(_ForumPost post) async {
    _readPostKeys.add(post.key);
    await _saveReadPostKeys();

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _markPostUnread(_ForumPost post) async {
    _readPostKeys.remove(post.key);
    await _saveReadPostKeys();

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _markPmRead(_ForumPrivateMessage pm) async {
    _readPmStamps[pm.key] = pm.sortStamp;
    await _saveReadPmStamps();
    if (!mounted) return;
    setState(() {});
  }


  Future<void> _openSetup() async {
    final updatedSources = await Navigator.of(context).push<List<ForumSource>>(
      MaterialPageRoute(
        builder: (_) => ForumSetupScreen(initialSources: _sources),
      ),
    );

    if (updatedSources == null) return;

    await _storage.saveSources(updatedSources);
    if (!mounted) return;
    setState(() {
      _sources = _normalizeSources(updatedSources);
      _posts.clear();
      _calendarEntries.clear();
      _privateMessages.clear();
      _status = 'Forum setup saved.';
    });
  }

  Future<void> _syncAll() async {
    final activeSources = _sources.where((s) => s.baseUrl.trim().isNotEmpty).toList();

    if (activeSources.isEmpty) {
      setState(() => _status = 'No forum accounts configured. Tap the gear to add them.');
      return;
    }

    setState(() {
      _isLoading = true;
      _status = 'Syncing forums...';
    });

    final posts = <_ForumPost>[];
    final calendarEntries = <_ForumCalendarEntry>[];
    final privateMessages = <_ForumPrivateMessage>[];

    for (final source in activeSources) {
      final service = SmfService(source: source);

      final loggedIn = await service.login();
      if (!loggedIn) continue;

      final unreadData = await service.fetchUnreadTopics();
      posts.addAll(_parsePosts(source, unreadData));

      final calendarData = await service.fetchCalendarEvents();
      calendarEntries.addAll(_parseCalendarEntries(source, calendarData));

      final pmData = await service.fetchPrivateMessages();
      privateMessages.addAll(_parsePrivateMessages(source, pmData));
    }

    // Auto-unhide PMs that received a new message since they were hidden
    for (final pm in privateMessages) {
      final hiddenStamp = _hiddenPmMap[pm.key];
      if (hiddenStamp != null && pm.sortStamp > hiddenStamp) {
        _hiddenPmMap.remove(pm.key);
      }
    }
    await _saveHiddenPmMap();

    // Auto-mark-unread posts that NodeBB now reports as unread again
    // (e.g. a new reply landed after we'd marked the post read locally).
    var readKeysChanged = false;
    for (final p in posts) {
      if (_readPostKeys.remove(p.key)) {
        readKeysChanged = true;
      }
    }
    if (readKeysChanged) {
      await _saveReadPostKeys();
    }

    if (!mounted) return;

    // Merge posts: keep all cached posts (read or unread), overlay with freshly fetched ones.
    final mergedPostMap = <String, _ForumPost>{for (final p in _posts) p.key: p};
    for (final p in posts) {
      mergedPostMap[p.key] = p;
    }
    final mergedPosts = mergedPostMap.values.toList()
      ..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));

    final mergedPms = privateMessages
        .where((pm) => pm.body.trim().isNotEmpty && pm.body.trim() != 'No messages in this chat')
        .toList()
      ..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));

    // Merge calendar: keep cached entries, overlay with freshly fetched ones.
    // If sync returned nothing (socket timeout etc.), cached entries are preserved.
    final mergedCalendarMap = <String, _ForumCalendarEntry>{
      for (final e in _calendarEntries) e.key: e,
    };
    for (final e in calendarEntries) {
      mergedCalendarMap[e.key] = e; // fresh data wins
    }
    final mergedCalendar = mergedCalendarMap.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    setState(() {
      _posts = mergedPosts;
      _calendarEntries = mergedCalendar;
      _privateMessages = mergedPms;
      _isLoading = false;
      _lastSyncTime = DateTime.now();
    });

    await _saveCache();

    // Update notification badge / status with current unread counts
    final unreadPosts = _posts.where((p) => !_readPostKeys.contains(p.key)).length;
    final unreadPms = _privateMessages.where((pm) {
      final lastRead = _readPmStamps[pm.key];
      return lastRead == null || pm.sortStamp > lastRead;
    }).length;

    if (mounted) {
      setState(() {
        _status = 'Sync complete. $unreadPosts unread post(s), ${_calendarEntries.length} calendar item(s), ${_privateMessages.length} PM(s).';
      });
    }

    await showNewContentNotification(unreadPosts, unreadPms);
  }

  String _decodeHtmlText(String value) {
    if (value.trim().isEmpty) return value;
    return html_parser.parseFragment(value).text?.trim() ?? value;
  }

  List<_ForumPost> _parsePosts(ForumSource source, Map<String, dynamic>? data) {
    if (data == null) return [];
    final rawTopics = data['topics'];
    if (rawTopics is! List) return [];

    return rawTopics.whereType<Map>().map((raw) {
      final topic = Map<String, dynamic>.from(raw);
      final tid = (topic['tid'] ?? topic['topic']?['tid'] ?? topic['slug'] ?? topic['title'] ?? '').toString();
      // Key is source+tid only — same topic with multiple unread replies must not appear multiple times
      final key = '${source.id}:$tid';
      final title = _decodeHtmlText((topic['title'] ?? topic['topic']?['title'] ?? 'Untitled post').toString());
      final author = _decodeHtmlText((topic['user']?['username'] ?? topic['username'] ?? 'Unknown').toString());
      final createdStamp = _parseForumStamp(topic['timestamp'] ?? topic['timestampISO'] ?? topic['createdAt']);
      final lastReplyStamp = _parseForumStamp(
        topic['lastposttime'] ?? topic['lastposttimeISO'] ?? topic['lastPostTime'] ?? topic['lastpost']?['timestamp'],
      );
      final sortStamp = lastReplyStamp != 0 ? lastReplyStamp : createdStamp;

      return _ForumPost(
        source: source,
        raw: topic,
        key: key,
        title: title,
        author: author,
        sortStamp: sortStamp,
        createdStamp: createdStamp,
        lastReplyStamp: lastReplyStamp,
      );
    }).where((p) => p.key.trim().isNotEmpty).toList();
  }

  List<_ForumCalendarEntry> _parseCalendarEntries(ForumSource source, List<Map<String, dynamic>> data) {
    return data.map((item) {
      final title = _decodeHtmlText((item['title'] ?? item['name'] ?? 'Calendar Entry').toString());
      final location = (item['location'] ?? '').toString().trim();
      final description = (item['description'] ?? item['content'] ?? '').toString().trim();
      final start = _parseForumDate(item['start'] ?? item['startDate'] ?? item['date']) ?? DateTime.now();
      final end = _parseForumDate(item['end'] ?? item['endDate']);

      // Key includes start timestamp so expanded recurring-event instances
      // (same pid, different dates) each get a unique key.
      final pid = (item['pid'] ?? '').toString().trim();
      final key = pid.isNotEmpty
          ? '${source.id}:cal:$pid:${start.millisecondsSinceEpoch}'
          : '${source.id}:cal:${start.millisecondsSinceEpoch}:$title';

      final detailLines = <String>[];
      if (location.isNotEmpty) detailLines.add('Location: $location');
      if (description.isNotEmpty) detailLines.add(description);

      return _ForumCalendarEntry(
        source: source,
        key: key,
        title: title,
        description: detailLines.join('\n\n'),
        start: start,
        end: end,
        url: (item['url'] ?? '').toString(),
      );
    }).toList();
  }

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



  int _parseForumStamp(dynamic value) {
    final parsed = _parseForumDate(value);
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  List<_ForumPrivateMessage> _parsePrivateMessages(ForumSource source, List<Map<String, dynamic>> data) {
    return data.map((item) {
      final title = _decodeHtmlText((item['title'] ?? item['subject'] ?? 'Private Message').toString());
      final sender = _decodeHtmlText((item['sender'] ?? item['from'] ?? item['username'] ?? 'Unknown').toString());
      final body = _decodeHtmlText((item['body'] ?? item['content'] ?? item['preview'] ?? '').toString());
      final stamp = int.tryParse((item['timestamp'] ?? item['time'] ?? 0).toString()) ?? 0;

      final roomId = (item['roomId'] ?? item['id'] ?? item['chatId'] ?? '').toString();
      final keyBase = roomId.isNotEmpty ? roomId : '$sender|$title';
      final key = '${source.id}:$keyBase';

      return _ForumPrivateMessage(
        source: source,
        key: key,
        roomId: roomId,
        title: title,
        sender: sender,
        body: body,
        sortStamp: stamp,
      );
    }).toList();
  }




  Future<void> _openPost(_ForumPost post) async {
    await _markPostRead(post);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ForumPostScreen(source: post.source, topic: post.raw),
      ),
    );
  }

  List<_ForumCalendarEntry> get _upcomingCalendarEntries {
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    return _calendarEntries.where((e) => !e.start.isBefore(today)).toList();
  }

  List<_ForumCalendarEntry> _entriesForDay(DateTime day) {
    return _calendarEntries.where((e) {
      final d = DateTime(e.start.year, e.start.month, e.start.day);
      return d == day;
    }).toList();
  }

  String _calendarDateHeader(DateTime day) {
    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    if (day == today) return 'Today';
    if (day == today.add(const Duration(days: 1))) return 'Tomorrow';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[day.weekday - 1]} ${months[day.month - 1]} ${day.day}';
  }

  @override
  Widget build(BuildContext context) {
    final onPostsTab = _tabController.index == 0;
    final onPmTab = _tabController.index == 2;
    final hasHiddenPms = _privateMessages.any((pm) => _hiddenPmMap.containsKey(pm.key));
    final hasReadPosts = _posts.any((p) => _readPostKeys.contains(p.key));

    return Scaffold(
        appBar: AppBar(
          title: const Text('Forum Scanner'),
          actions: [
            if (onPostsTab && hasReadPosts)
              IconButton(
                icon: Icon(_showReadPosts ? Icons.visibility : Icons.visibility_off),
                tooltip: _showReadPosts ? 'Hide read posts' : 'Show read posts',
                onPressed: () => setState(() => _showReadPosts = !_showReadPosts),
              ),
            if (onPmTab && hasHiddenPms)
              IconButton(
                icon: Icon(_showHiddenPms ? Icons.visibility : Icons.visibility_off),
                tooltip: _showHiddenPms ? 'Hide hidden PMs' : 'Show hidden PMs',
                onPressed: () => setState(() => _showHiddenPms = !_showHiddenPms),
              ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Forum accounts',
              onPressed: _openSetup,
            ),
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sync all forums',
              onPressed: _isLoading ? null : _syncAll,
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.forum), text: 'Posts'),
              Tab(icon: Icon(Icons.calendar_month), text: 'Calendar'),
              Tab(icon: Icon(Icons.mail), text: "PM's"),
            ],
          ),
        ),
        body: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_status),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildPostsTab(),
                  _buildCalendarTab(),
                  _buildPrivateMessagesTab(),
                ],
              ),
            ),
          ],
        ),
    );
  }

  Widget _buildPostsTab() {
    if (_posts.isEmpty) {
      return const _EmptyState(icon: Icons.mark_chat_read, message: 'No posts to show.');
    }

    final query = _postSearchQuery.trim().toLowerCase();

    final visible = _posts.where((p) {
      final isRead = _readPostKeys.contains(p.key);
      if (isRead && !_showReadPosts) return false;

      if (query.isEmpty) return true;
      return p.title.toLowerCase().contains(query) ||
          p.author.toLowerCase().contains(query) ||
          p.source.name.toLowerCase().contains(query);
    }).toList();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _postSearchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search posts...',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _postSearchQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _postSearchController.clear();
                        setState(() => _postSearchQuery = '');
                        FocusScope.of(context).unfocus();
                      },
                    ),
            ),
            onChanged: (value) => setState(() => _postSearchQuery = value),
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? _EmptyState(
                  icon: Icons.mark_chat_read,
                  message: query.isNotEmpty
                      ? 'No posts match your search.'
                      : 'No unread posts. Tap the eye icon to show read posts.',
                )
              : RefreshIndicator(
                  onRefresh: _syncAll,
                  child: ListView.separated(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = visible[index];
                      final color = Color(post.source.colorValue);
                      final isRead = _readPostKeys.contains(post.key);

                      return Container(
                        color: isRead ? null : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                        child: ListTile(
                          leading: CircleAvatar(backgroundColor: color, radius: 8),
                          title: Text(
                            post.title,
                            style: TextStyle(
                              fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                              color: isRead ? Theme.of(context).disabledColor : null,
                            ),
                          ),
                          subtitle: Text(_postSubtitle(post)),
                          onTap: () async {
                            FocusScope.of(context).unfocus();
                            await _markPostRead(post);
                            if (!mounted) return;
                            await _openPost(post);
                          },
                          trailing: IconButton(
                            icon: Icon(
                              isRead ? Icons.undo : Icons.check,
                              size: 20,
                              color: isRead ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor,
                            ),
                            tooltip: isRead ? 'Mark unread' : 'Mark read',
                            onPressed: () => isRead ? _markPostUnread(post) : _markPostRead(post),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
      ),
    );
  }

  String _postSubtitle(_ForumPost post) {
    final pieces = <String>[post.source.name, post.author];

    if (post.createdStamp > 0) {
      pieces.add('Posted ${_formatDateTime(DateTime.fromMillisecondsSinceEpoch(post.createdStamp))}');
    }

    if (post.lastReplyStamp > 0 && post.lastReplyStamp != post.createdStamp) {
      pieces.add('Last reply ${_formatDateTime(DateTime.fromMillisecondsSinceEpoch(post.lastReplyStamp))}');
    }

    return pieces.join(' • ');
  }

  Widget _buildCalendarTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'list',     icon: Icon(Icons.view_list),     label: Text('List')),
              ButtonSegment(value: 'calendar', icon: Icon(Icons.calendar_month), label: Text('Calendar')),
            ],
            selected: {_calendarView},
            onSelectionChanged: (s) => setState(() => _calendarView = s.first),
          ),
        ),
        Expanded(
          child: _calendarView == 'list'
              ? _buildCalendarListView()
              : _buildCalendarGridView(),
        ),
      ],
    );
  }

  Widget _buildCalendarListView() {
    final entries = _upcomingCalendarEntries;
    if (entries.isEmpty) {
      return const _EmptyState(icon: Icons.event_busy, message: 'No upcoming calendar events.');
    }

    // Group by date
    final Map<DateTime, List<_ForumCalendarEntry>> grouped = {};
    for (final e in entries) {
      final day = DateTime(e.start.year, e.start.month, e.start.day);
      grouped.putIfAbsent(day, () => []).add(e);
    }
    final sortedDays = grouped.keys.toList()..sort();

    // Build a flat list of header + event items
    final List<dynamic> items = []; // String = header, _ForumCalendarEntry = event
    for (final day in sortedDays) {
      items.add(day); // date header
      items.addAll(grouped[day]!);
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is DateTime) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              _calendarDateHeader(item),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          );
        }
        final entry = item as _ForumCalendarEntry;
        final color = Color(entry.source.colorValue);
        final time = '${entry.start.hour.toString().padLeft(2, '0')}:${entry.start.minute.toString().padLeft(2, '0')}';
        return ListTile(
          leading: CircleAvatar(backgroundColor: color, radius: 8),
          title: Text(entry.title),
          subtitle: Text('${entry.source.name} • $time'),
          onTap: () => _showCalendarDetails(entry),
        );
      },
    );
  }

  // Short time label: "9a", "12p", "5:30p"
  String _shortTime(DateTime dt) {
    final h = dt.hour;
    final m = dt.minute;
    final ampm = h < 12 ? 'a' : 'p';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return m == 0 ? '$h12$ampm' : '$h12:${m.toString().padLeft(2,'0')}$ampm';
  }

  Widget _buildCalendarGridView() {
    final year  = _calendarDisplayMonth.year;
    final month = _calendarDisplayMonth.month;
    final firstDay = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final startOffset = firstDay.weekday % 7; // Sun=0, Mon=1, …, Sat=6

    const monthNames = ['January','February','March','April','May','June',
                        'July','August','September','October','November','December'];
    const dowLabels  = ['Su','Mo','Tu','We','Th','Fr','Sa'];

    final today = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    // Pre-bucket events by day
    final Map<DateTime, List<_ForumCalendarEntry>> byDay = {};
    for (final e in _calendarEntries) {
      final d = DateTime(e.start.year, e.start.month, e.start.day);
      byDay.putIfAbsent(d, () => []).add(e);
    }

    // Build list of week rows (each week = 7 day slots)
    final int totalSlots = startOffset + daysInMonth;
    final int numWeeks = (totalSlots / 7).ceil();

    final gridWidth = MediaQuery.of(context).size.width;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Month navigation header (stays fixed — not affected by zoom/pan)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() {
                  _calendarDisplayMonth = DateTime(year, month - 1);
                  _calendarTransformController.value = Matrix4.identity();
                  _calendarZoom = 1.0;
                }),
              ),
              Expanded(
                child: Text(
                  '${monthNames[month - 1]} $year',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() {
                  _calendarDisplayMonth = DateTime(year, month + 1);
                  _calendarTransformController.value = Matrix4.identity();
                  _calendarZoom = 1.0;
                }),
              ),
            ],
          ),
        ),
        if (_calendarZoom > 1.01)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Pinch to zoom • drag to pan',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    _calendarTransformController.value = Matrix4.identity();
                    setState(() => _calendarZoom = 1.0);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      children: [
                        Icon(Icons.zoom_out_map, size: 14, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 2),
                        Text(
                          'Reset',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Zoomable / pannable month grid
        Expanded(
          child: ClipRect(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _calendarActivePointers++;
                if (_calendarActivePointers >= 2) _calendarMultiTouch = true;
              },
              onPointerUp: (_) {
                _calendarActivePointers = (_calendarActivePointers - 1).clamp(0, 10);
                if (_calendarActivePointers == 0) {
                  Future.delayed(const Duration(milliseconds: 250), () {
                    _calendarMultiTouch = false;
                  });
                }
              },
              onPointerCancel: (_) {
                _calendarActivePointers = (_calendarActivePointers - 1).clamp(0, 10);
              },
              child: InteractiveViewer(
              transformationController: _calendarTransformController,
              minScale: 1.0,
              maxScale: 4.0,
              boundaryMargin: EdgeInsets.zero,
              constrained: false,
              panEnabled: _calendarZoom > 1.01,
              scaleEnabled: true,
              onInteractionEnd: (details) {
                final scale = _calendarTransformController.value.getMaxScaleOnAxis();
                if ((scale - _calendarZoom).abs() > 0.001) setState(() => _calendarZoom = scale);
              },
              child: SizedBox(
                  width: gridWidth,
                  child: Table(
                    border: TableBorder.all(
                      color: Theme.of(context).dividerColor,
                      width: 0.5,
                    ),
                    columnWidths: const {0:FlexColumnWidth(),1:FlexColumnWidth(),2:FlexColumnWidth(),
                                           3:FlexColumnWidth(),4:FlexColumnWidth(),5:FlexColumnWidth(),6:FlexColumnWidth()},
                    children: [
                      TableRow(
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        children: dowLabels.map((d) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Center(
                            child: Text(d,
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )).toList(),
                      ),
                      // Week rows
                      ...List.generate(numWeeks, (weekIdx) {
                        return TableRow(
                          children: List.generate(7, (colIdx) {
                            final slot = weekIdx * 7 + colIdx;
                            final dayNum = slot - startOffset + 1;
                            if (dayNum < 1 || dayNum > daysInMonth) {
                              return const SizedBox(height: 60);
                            }
                            final day = DateTime(year, month, dayNum);
                            final isToday = day == today;
                            final events = byDay[day] ?? [];
                            const maxVisible = 3;
                            final visible = events.take(maxVisible).toList();
                            final overflow = events.length - maxVisible;

                            return GestureDetector(
                              onTap: events.isEmpty ? null : () {
                                // Briefly delay opening: if a second finger comes
                                // down right after this (start of a pinch), skip it.
                                Future.delayed(const Duration(milliseconds: 150), () {
                                  if (!mounted || _calendarMultiTouch) return;
                                  showModalBottomSheet(
                                    context: context,
                                    builder: (_) => _buildDayEventsSheet(day, events),
                                  );
                                });
                              },
                              child: Container(
                                constraints: const BoxConstraints(minHeight: 60),
                                decoration: BoxDecoration(
                                  color: isToday
                                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4)
                                      : null,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Day number
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2, left: 3, right: 2),
                                      child: Text(
                                        '$dayNum',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                                          color: isToday
                                              ? Theme.of(context).colorScheme.primary
                                              : null,
                                        ),
                                      ),
                                    ),
                                    // Event chips
                                    ...visible.map((e) => _buildEventChip(e)),
                                    if (overflow > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 2, bottom: 2),
                                        child: Text(
                                          '+$overflow more',
                                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEventChip(_ForumCalendarEntry entry) {
    final bg = Color(entry.source.colorValue);
    // Pick white or black text based on background luminance
    final luminance = bg.computeLuminance();
    final fg = luminance > 0.4 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTap: () {
        // Briefly delay opening: if a second finger comes down right after
        // this (start of a pinch), skip it.
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted || _calendarMultiTouch) return;
          _showCalendarDetails(entry);
        });
      },
      child: Container(
        margin: const EdgeInsets.only(left: 1, right: 1, bottom: 1),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          '${_shortTime(entry.start)} ${entry.title}',
          style: TextStyle(fontSize: 9, color: fg, height: 1.2),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildDayEventsSheet(DateTime day, List<_ForumCalendarEntry> events) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _calendarDateHeader(day),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: events.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = events[i];
                final color = Color(e.source.colorValue);
                return ListTile(
                  leading: CircleAvatar(backgroundColor: color, radius: 8),
                  title: Text(e.title),
                  subtitle: Text('${e.source.name} • ${_shortTime(e.start)}'),
                  onTap: () {
                    Navigator.pop(context);
                    _showCalendarDetails(e);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivateMessagesTab() {
    final hasHidden = _privateMessages.any((pm) => _hiddenPmMap.containsKey(pm.key));
    final visible = _showHiddenPms
        ? _privateMessages
        : _privateMessages.where((pm) => !_hiddenPmMap.containsKey(pm.key)).toList();

    if (!hasHidden && visible.isEmpty) {
      return const _EmptyState(icon: Icons.mail_outline, message: 'No private messages found.');
    }

    return Column(
      children: [

        Expanded(
          child: visible.isEmpty
              ? const _EmptyState(icon: Icons.mail_outline, message: 'No visible messages. Tap "Show hidden" to see hidden ones.')
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final pm = visible[index];
                    final color = Color(pm.source.colorValue);
                    // Unread if never opened, or new messages arrived since last read
                    final lastReadStamp = _readPmStamps[pm.key];
                    final isRead = lastReadStamp != null && pm.sortStamp <= lastReadStamp;
                    final isHidden = _hiddenPmMap.containsKey(pm.key);

                    return Container(
                      color: isRead ? null : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                      child: ListTile(
                        leading: CircleAvatar(backgroundColor: color, radius: 8),
                        title: Text(
                          pm.title,
                          style: TextStyle(
                            fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                            color: isHidden ? Theme.of(context).disabledColor : null,
                          ),
                        ),
                        subtitle: Text('${pm.source.name} • ${pm.sender} • ${_formatPmTimestamp(pm.sortStamp)}'),
                        onTap: () async {
                          await _markPmRead(pm);
                          if (!mounted) return;
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ForumPmScreen(pm: pm),
                            ),
                          );
                        },
                        trailing: IconButton(
                          icon: Icon(
                            isHidden ? Icons.visibility : Icons.visibility_off,
                            size: 20,
                            color: isHidden ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor,
                          ),
                          tooltip: isHidden ? 'Unhide' : 'Hide',
                          onPressed: () => _toggleHidePm(pm),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showCalendarDetails(_ForumCalendarEntry entry) {
    final timeStr = '${entry.start.hour.toString().padLeft(2, '0')}:${entry.start.minute.toString().padLeft(2, '0')}';
    final when = entry.end == null
        ? '${_calendarDateHeader(DateTime(entry.start.year, entry.start.month, entry.start.day))} at $timeStr'
        : '${_calendarDateHeader(DateTime(entry.start.year, entry.start.month, entry.start.day))} at $timeStr'
          ' – ${entry.end!.hour.toString().padLeft(2, '0')}:${entry.end!.minute.toString().padLeft(2, '0')}';

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(entry.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                CircleAvatar(backgroundColor: Color(entry.source.colorValue), radius: 6),
                const SizedBox(width: 8),
                Text(entry.source.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 6),
              Text(when),
              if (entry.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(entry.description),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  void _showPmDetails(_ForumPrivateMessage pm) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(pm.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(pm.source.name),
              Text('From: ${pm.sender}'),
              Text('Date: ${_formatPmTimestamp(pm.sortStamp)}'),
              const SizedBox(height: 16),

              HtmlPostContent(
                html: pm.body,
                baseUrl: pm.source.baseUrl,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  String _formatDateTime(DateTime value) {
    final date = '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final time = '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

class ForumPostScreen extends StatefulWidget {
  final ForumSource source;
  final Map<String, dynamic> topic;

  const ForumPostScreen({super.key, required this.source, required this.topic});

  @override
  State<ForumPostScreen> createState() => _ForumPostScreenState();
}

class _ForumPostScreenState extends State<ForumPostScreen> {
  late final SmfService _service;
  Map<String, dynamic>? _details;
  bool _isLoading = true;
  bool _isReplying = false;
  final _replyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _service = SmfService(source: widget.source);
    _loadDetails();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    await _service.login();
    final details = await _service.fetchTopicDetails(widget.topic);
    if (!mounted) return;
    setState(() {
      _details = details;
      _isLoading = false;
    });
  }

  Future<void> _reply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isReplying = true);
    final ok = await _service.replyToTopic(widget.topic, text);

    if (!mounted) return;
    setState(() => _isReplying = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Reply posted.' : 'Reply failed.')));
    if (ok) _replyController.clear();
  }

  String _threadPostHeader(int postNumber, String author, dynamic timestamp) {
    final dateText = _formatThreadTimestamp(timestamp);
    if (dateText.isEmpty) return 'Reply #$postNumber • $author';
    return 'Reply #$postNumber • $author • $dateText';
  }

  String _formatThreadTimestamp(dynamic value) {
    if (value == null) return '';

    DateTime? dt;
    int? numeric;

    if (value is DateTime) {
      dt = value;
    } else if (value is int) {
      numeric = value;
    } else if (value is double) {
      numeric = value.round();
    } else {
      final text = value.toString().trim();
      if (text.isEmpty) return '';

      numeric = int.tryParse(text);
      if (numeric == null) {
        dt = DateTime.tryParse(text);
      }
    }

    if (dt == null && numeric != null) {
      if (numeric.abs() < 100000000000) {
        dt = DateTime.fromMillisecondsSinceEpoch(numeric * 1000);
      } else {
        dt = DateTime.fromMillisecondsSinceEpoch(numeric);
      }
    }

    if (dt == null) return '';

    final date = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }



  @override
  Widget build(BuildContext context) {
    final title = _decodeHtmlText((_details?['title'] ?? widget.topic['title'] ?? 'Forum Post').toString());
    final rawPosts = _details?['posts'];
    final threadPosts = rawPosts is List ? rawPosts.whereType<Map>().toList() : <Map>[];
    final fallbackAuthor = _decodeHtmlText((_details?['author'] ?? 'Unknown').toString());
    final fallbackContent = (_details?['content'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: Text(widget.source.name)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: threadPosts.isEmpty ? 1 : threadPosts.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
                        );
                      }

                      final post = threadPosts.isEmpty ? null : threadPosts[index - 1];
                      final author = _decodeHtmlText((post?['author'] ?? fallbackAuthor).toString());
                      final content = (post?['content'] ?? fallbackContent).toString();
                      final htmlContent = (post?['htmlContent'] ?? content).toString();
                      final postNumber = threadPosts.isEmpty ? 1 : index;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _threadPostHeader(postNumber, author, post?['timestamp']),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 24),
                              HtmlPostContent(
                                html: htmlContent.isEmpty ? content : htmlContent,
                                baseUrl: widget.source.baseUrl,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replyController,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              hintText: 'Write a reply...',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          icon: _isReplying
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send),
                          onPressed: _isReplying ? null : _reply,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class ForumPmScreen extends StatefulWidget {
  final _ForumPrivateMessage pm;

  const ForumPmScreen({super.key, required this.pm});

  @override
  State<ForumPmScreen> createState() => _ForumPmScreenState();
}

class _ForumPmScreenState extends State<ForumPmScreen> {
  late final SmfService _service;
  bool _isLoading = true;
  bool _isSending = false;
  List<Map<String, dynamic>> _messages = [];
  final _replyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _service = SmfService(source: widget.pm.source);
    _loadConversation();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || widget.pm.roomId.trim().isEmpty) return;

    setState(() => _isSending = true);
    final ok = await _service.sendChatMessage(widget.pm.roomId, text);

    if (!mounted) return;
    setState(() => _isSending = false);

    if (ok) {
      _replyController.clear();
      await _loadConversation();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send message.')),
      );
    }
  }

  Future<void> _loadConversation() async {
    await _service.login();

    if (widget.pm.roomId.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _messages = [
          {
            'sender': widget.pm.sender,
            'body': widget.pm.body,
            'timestamp': widget.pm.sortStamp,
          }
        ];
        _isLoading = false;
      });
      return;
    }

    final messages = await _service.fetchPrivateMessageThread(widget.pm.roomId);

    if (!mounted) return;

    final rawList = messages.isNotEmpty
        ? messages
        : [
      {
        'sender': widget.pm.sender,
        'body': widget.pm.body,
        'timestamp': widget.pm.sortStamp,
      }
    ];

    // Filter out system user-join notifications, then reverse so newest is on top
    final filtered = rawList.where((m) {
      final type = (m['type'] ?? '').toString();
      final system = m['system'];
      final body = (m['body'] ?? m['content'] ?? '').toString().trim().toLowerCase();
      return type != 'user-join' && system != true && body != 'user-join';
    }).toList().reversed.toList();

    setState(() {
      _messages = filtered;
      _isLoading = false;
    });
  }

  String _formatDateTime(DateTime value) {
    final date = '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final time = '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  String _formatPmTimestamp(dynamic value) {
    DateTime? dt;
    int? numeric;

    if (value == null) return 'Unknown time';
    if (value is DateTime) {
      dt = value;
    } else if (value is int) {
      numeric = value;
    } else if (value is double) {
      numeric = value.round();
    } else {
      final text = value.toString().trim();
      if (text.isEmpty) return 'Unknown time';
      numeric = int.tryParse(text);
      if (numeric == null) {
        dt = DateTime.tryParse(text);
      }
    }

    if (dt == null && numeric != null) {
      if (numeric.abs() < 100000000000) {
        dt = DateTime.fromMillisecondsSinceEpoch(numeric * 1000);
      } else {
        dt = DateTime.fromMillisecondsSinceEpoch(numeric);
      }
    }

    if (dt == null) return 'Unknown time';
    return _formatDateTime(dt);
  }

  @override
  Widget build(BuildContext context) {
    final canReply = widget.pm.roomId.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(widget.pm.title)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (canReply)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _replyController,
                              minLines: 1,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'Write a reply...',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            icon: _isSending
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.send),
                            onPressed: _isSending ? null : _sendReply,
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: _messages.isEmpty
                      ? const Center(child: Text('No conversation messages found.'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final item = _messages[index];
                            final sender = _decodeHtmlText((item['sender'] ?? item['from'] ?? 'Unknown').toString());
                            final body = (item['body'] ?? item['content'] ?? '').toString();
                            final stamp = item['timestamp'];

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$sender • ${_formatPmTimestamp(stamp)}',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const Divider(height: 20),
                                    HtmlPostContent(
                                      html: body,
                                      baseUrl: widget.pm.source.baseUrl,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}


class HtmlPostContent extends StatelessWidget {
  final String html;
  final String baseUrl;

  const HtmlPostContent({super.key, required this.html, required this.baseUrl});

  @override
  Widget build(BuildContext context) {
    final document = html_parser.parseFragment(html);
    final widgets = <Widget>[];

    for (final node in document.nodes) {
      widgets.addAll(_nodeToWidgets(context, node));
    }

    if (widgets.isEmpty) {
      final fallback = html_parser.parse(html).body?.text.trim() ?? html.trim();
      return Text(fallback.isEmpty ? 'No post body found.' : fallback);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildLinkedText(BuildContext context, String text) {
    final urlPattern = RegExp(r'(https?:\/\/[^\s]+)');
    final matches = urlPattern.allMatches(text).toList();

    if (matches.isEmpty) {
      return SelectableText(text);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final rawUrl = match.group(0)!;
      final url = _stripTrailingPunctuation(rawUrl);

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: InkWell(
            onTap: () => launchUrlString(url, mode: LaunchMode.externalApplication),
            child: Text(
              url,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      );

      if (rawUrl.length > url.length) {
        spans.add(TextSpan(text: rawUrl.substring(url.length)));
      }

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return SelectableText.rich(
      TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: spans,
      ),
    );
  }


  String _stripTrailingPunctuation(String url) {
    while (url.isNotEmpty && '.,);!?]'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }


  List<Widget> _nodeToWidgets(BuildContext context, dom.Node node) {
    if (node is dom.Text) {
      final text = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return const [];
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildLinkedText(context, text),
        ),
      ];
    }


    if (node is! dom.Element) return const [];

    final tag = node.localName?.toLowerCase() ?? '';

    if (tag == 'br') return const [SizedBox(height: 8)];

    if (tag == 'img') {
      final src = node.attributes['src'] ?? node.attributes['data-src'];
      if (src == null || src.trim().isEmpty) return const [];
      final imageUrl = _absoluteUrl(src.trim());
      return [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              imageUrl,
              fit: BoxFit.contain,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              },
              errorBuilder: (context, error, stackTrace) => Text(
                'Image could not be loaded: $imageUrl',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ),
      ];
    }

    if (tag == 'a') {
      final href = node.attributes['href'];
      final text = node.text.trim().isEmpty ? (href ?? 'link') : node.text.trim();
      final url = href == null ? null : _absoluteUrl(href.trim());
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: url == null ? null : () => launchUrlString(url, mode: LaunchMode.externalApplication),
            child: Text(
              text,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ];
    }

    final children = <Widget>[];
    for (final child in node.nodes) {
      children.addAll(_nodeToWidgets(context, child));
    }

    if (children.isEmpty) return const [];

    if (tag == 'p' || tag == 'div' || tag == 'blockquote' || tag == 'li') {
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ];
    }

    return children;
  }

  String _absoluteUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return '$base$url';
    return '$base/$url';
  }
}

class ForumSetupScreen extends StatefulWidget {
  final List<ForumSource> initialSources;

  const ForumSetupScreen({super.key, required this.initialSources});

  @override
  State<ForumSetupScreen> createState() => _ForumSetupScreenState();
}

class _ForumSetupScreenState extends State<ForumSetupScreen> {
  late final List<_ForumSourceControllers> _controllers;

  @override
  void initState() {
    super.initState();
    final colors = <int>[Colors.blue.toARGB32(), Colors.green.toARGB32(), Colors.deepOrange.toARGB32()];
    final sources = List<ForumSource>.from(widget.initialSources);

    while (sources.length < 3) {
      final i = sources.length;
      sources.add(ForumSource(
        id: 'forum_${i + 1}',
        name: 'Forum ${i + 1}',
        baseUrl: '',
        username: '',
        password: '',
        colorValue: colors[i],
      ));
    }

    _controllers = sources.take(3).map((source) => _ForumSourceControllers(source)).toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final sources = <ForumSource>[];

    for (int i = 0; i < _controllers.length; i++) {
      final c = _controllers[i];
      sources.add(ForumSource(
        id: c.id,
        name: c.name.text.trim().isEmpty ? 'Forum ${i + 1}' : c.name.text.trim(),
        baseUrl: c.baseUrl.text.trim(),
        username: c.username.text.trim(),
        password: c.password.text,
        colorValue: c.colorValue,
      ));
    }

    Navigator.of(context).pop(sources);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Forum Accounts'),
        actions: [IconButton(icon: const Icon(Icons.save), tooltip: 'Save', onPressed: _save)],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _controllers.length,
        itemBuilder: (context, index) {
          final c = _controllers[index];
          final color = Color(c.colorValue);

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(backgroundColor: color, radius: 8),
                      const SizedBox(width: 8),
                      Text('Forum ${index + 1}', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  TextField(controller: c.name, decoration: const InputDecoration(labelText: 'Display Name')),
                  TextField(controller: c.baseUrl, decoration: const InputDecoration(labelText: 'Forum Base URL'), keyboardType: TextInputType.url),
                  TextField(controller: c.username, decoration: const InputDecoration(labelText: 'Username')),
                  TextField(controller: c.password, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ForumSourceControllers {
  final String id;
  final int colorValue;
  final TextEditingController name;
  final TextEditingController baseUrl;
  final TextEditingController username;
  final TextEditingController password;

  _ForumSourceControllers(ForumSource source)
      : id = source.id,
        colorValue = source.colorValue,
        name = TextEditingController(text: source.name),
        baseUrl = TextEditingController(text: source.baseUrl),
        username = TextEditingController(text: source.username),
        password = TextEditingController(text: source.password);

  void dispose() {
    name.dispose();
    baseUrl.dispose();
    username.dispose();
    password.dispose();
  }
}

class _ForumPost {
  final ForumSource source;
  final Map<String, dynamic> raw;
  final String key;
  final String title;
  final String author;
  final int sortStamp;
  final int createdStamp;
  final int lastReplyStamp;

  _ForumPost({
    required this.source,
    required this.raw,
    required this.key,
    required this.title,
    required this.author,
    required this.sortStamp,
    required this.createdStamp,
    required this.lastReplyStamp,
  });
}

class _ForumCalendarEntry {
  final ForumSource source;
  final String key;       // dedup key: sourceId:pid or sourceId:start:title
  final String title;
  final String description;
  final DateTime start;
  final DateTime? end;
  final String url;

  _ForumCalendarEntry({required this.source, required this.key, required this.title, required this.description, required this.start, required this.end, required this.url});
}

class _ForumPrivateMessage {
  final ForumSource source;
  final String key;
  final String roomId;
  final String title;
  final String sender;
  final String body;
  final int sortStamp;

  _ForumPrivateMessage({
    required this.source,
    required this.key,
    required this.roomId,
    required this.title,
    required this.sender,
    required this.body,
    required this.sortStamp,
  });
}



class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
