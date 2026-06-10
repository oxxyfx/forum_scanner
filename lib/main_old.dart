import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forum_source.dart';
import 'smf_service.dart';
import 'storage_service.dart';

void main() {
  runApp(const ForumAggregatorApp());
}

class ForumAggregatorApp extends StatelessWidget {
  const ForumAggregatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forum Aggregator',
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

class _ForumAggregatorHomeState extends State<ForumAggregatorHome> {
  final StorageService _storage = StorageService();

  List<ForumSource> _sources = [];
  List<_ForumPost> _posts = [];
  List<_ForumCalendarEntry> _calendarEntries = [];
  List<_ForumPrivateMessage> _privateMessages = [];
  Set<String> _readPostKeys = <String>{};

  bool _isLoading = false;
  String _status = 'Ready';
  String _calendarRange = 'week';

  @override
  void initState() {
    super.initState();
    _loadEverything();
  }

  Future<void> _loadEverything() async {
    final sources = await _storage.loadSources();
    final readKeys = await _loadReadPostKeys();

    if (!mounted) return;
    setState(() {
      _sources = _normalizeSources(sources);
      _readPostKeys = readKeys;
      _status = sources.isEmpty ? 'Open setup to add forum accounts.' : 'Loaded ${sources.length} forum account(s).';
    });
  }

  List<ForumSource> _normalizeSources(List<ForumSource> saved) {
    final colors = <int>[
      Colors.blue.value,
      Colors.green.value,
      Colors.deepOrange.value,
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

  Future<Set<String>> _loadReadPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('read_post_keys')?.toSet() ?? <String>{};
  }

  Future<void> _saveReadPostKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('read_post_keys', _readPostKeys.toList());
  }

  Future<void> _markPostRead(_ForumPost post) async {
    _readPostKeys.add(post.key);
    await _saveReadPostKeys();

    if (!mounted) return;
    setState(() {
      _posts = _posts.where((p) => p.key != post.key).toList();
    });
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
      _posts.clear();
      _calendarEntries.clear();
      _privateMessages.clear();
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

    if (!mounted) return;
    setState(() {
      _posts = posts.where((p) => !_readPostKeys.contains(p.key)).toList()
        ..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));
      _calendarEntries = calendarEntries..sort((a, b) => a.start.compareTo(b.start));
      _privateMessages = privateMessages..sort((a, b) => b.sortStamp.compareTo(a.sortStamp));
      _isLoading = false;
      _status = 'Sync complete. ${_posts.length} unread post(s), ${_calendarEntries.length} calendar item(s), ${_privateMessages.length} PM(s).';
    });
  }

  List<_ForumPost> _parsePosts(ForumSource source, Map<String, dynamic>? data) {
    if (data == null) return [];
    final rawTopics = data['topics'];
    if (rawTopics is! List) return [];

    return rawTopics.whereType<Map>().map((raw) {
      final topic = Map<String, dynamic>.from(raw);
      final tid = (topic['tid'] ?? topic['topic']?['tid'] ?? topic['slug'] ?? topic['title'] ?? '').toString();
      final pid = (topic['pid'] ?? topic['index'] ?? '').toString();
      final key = '${source.id}:$tid:$pid';
      final title = (topic['title'] ?? topic['topic']?['title'] ?? 'Untitled post').toString();
      final author = (topic['user']?['username'] ?? topic['username'] ?? 'Unknown').toString();
      final stamp = int.tryParse((topic['timestamp'] ?? topic['lastposttime'] ?? 0).toString()) ?? 0;

      return _ForumPost(
        source: source,
        raw: topic,
        key: key,
        title: title,
        author: author,
        sortStamp: stamp,
      );
    }).where((p) => p.key.trim().isNotEmpty).toList();
  }

  List<_ForumCalendarEntry> _parseCalendarEntries(ForumSource source, List<Map<String, dynamic>> data) {
    return data.map((item) {
      final title = (item['title'] ?? item['name'] ?? 'Calendar Entry').toString();
      final description = (item['description'] ?? item['content'] ?? '').toString();
      final start = DateTime.tryParse((item['start'] ?? item['date'] ?? '').toString()) ?? DateTime.now();
      final end = DateTime.tryParse((item['end'] ?? '').toString());
      return _ForumCalendarEntry(
        source: source,
        title: title,
        description: description,
        start: start,
        end: end,
        url: (item['url'] ?? '').toString(),
      );
    }).toList();
  }

  List<_ForumPrivateMessage> _parsePrivateMessages(ForumSource source, List<Map<String, dynamic>> data) {
    return data.map((item) {
      final title = (item['title'] ?? item['subject'] ?? 'Private Message').toString();
      final sender = (item['sender'] ?? item['from'] ?? item['username'] ?? 'Unknown').toString();
      final body = (item['body'] ?? item['content'] ?? item['preview'] ?? '').toString();
      final stamp = int.tryParse((item['timestamp'] ?? item['time'] ?? 0).toString()) ?? 0;
      return _ForumPrivateMessage(
        source: source,
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

  List<_ForumCalendarEntry> get _visibleCalendarEntries {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (_calendarRange == 'day') {
      final tomorrow = today.add(const Duration(days: 1));
      return _calendarEntries.where((e) => !e.start.isBefore(today) && e.start.isBefore(tomorrow)).toList();
    }

    if (_calendarRange == 'month') {
      final first = DateTime(today.year, today.month, 1);
      final next = DateTime(today.year, today.month + 1, 1);
      return _calendarEntries.where((e) => !e.start.isBefore(first) && e.start.isBefore(next)).toList();
    }

    final weekEnd = today.add(const Duration(days: 7));
    return _calendarEntries.where((e) => !e.start.isBefore(today) && e.start.isBefore(weekEnd)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Forum Aggregator'),
          actions: [
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
          bottom: const TabBar(
            tabs: [
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
                children: [
                  _buildPostsTab(),
                  _buildCalendarTab(),
                  _buildPrivateMessagesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostsTab() {
    if (_posts.isEmpty) {
      return const _EmptyState(icon: Icons.mark_chat_read, message: 'No unread posts to show.');
    }

    return RefreshIndicator(
      onRefresh: _syncAll,
      child: ListView.separated(
        itemCount: _posts.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final post = _posts[index];
          final color = Color(post.source.colorValue);

          return ListTile(
            leading: CircleAvatar(backgroundColor: color, radius: 8),
            title: Text(post.title),
            subtitle: Text('${post.source.name} • ${post.author}'),
            onTap: () => _openPost(post),
            trailing: IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Mark read',
              onPressed: () => _markPostRead(post),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCalendarTab() {
    final visibleEntries = _visibleCalendarEntries;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'day', label: Text('Day')),
              ButtonSegment(value: 'week', label: Text('Week')),
              ButtonSegment(value: 'month', label: Text('Month')),
            ],
            selected: {_calendarRange},
            onSelectionChanged: (selection) => setState(() => _calendarRange = selection.first),
          ),
        ),
        Expanded(
          child: visibleEntries.isEmpty
              ? const _EmptyState(icon: Icons.event_busy, message: 'No calendar entries found for this range.')
              : ListView.separated(
                  itemCount: visibleEntries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = visibleEntries[index];
                    final color = Color(entry.source.colorValue);
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: color, radius: 8),
                      title: Text(entry.title),
                      subtitle: Text('${entry.source.name} • ${_formatDateTime(entry.start)}'),
                      onTap: () => _showCalendarDetails(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPrivateMessagesTab() {
    if (_privateMessages.isEmpty) {
      return const _EmptyState(icon: Icons.mail_outline, message: 'No private messages found.');
    }

    return ListView.separated(
      itemCount: _privateMessages.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final pm = _privateMessages[index];
        final color = Color(pm.source.colorValue);

        return ListTile(
          leading: CircleAvatar(backgroundColor: color, radius: 8),
          title: Text(pm.title),
          subtitle: Text('${pm.source.name} • ${pm.sender}'),
          onTap: () => _showPmDetails(pm),
        );
      },
    );
  }

  void _showCalendarDetails(_ForumCalendarEntry entry) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(entry.title),
        content: SingleChildScrollView(
          child: Text('${entry.source.name}\n${_formatDateTime(entry.start)}\n\n${entry.description}'),
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
        content: SingleChildScrollView(child: Text('${pm.source.name}\nFrom: ${pm.sender}\n\n${pm.body}')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
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

  @override
  Widget build(BuildContext context) {
    final title = (_details?['title'] ?? widget.topic['title'] ?? 'Forum Post').toString();
    final author = (_details?['author'] ?? 'Unknown').toString();
    final content = (_details?['content'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: Text(widget.source.name)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text('By $author', style: Theme.of(context).textTheme.bodySmall),
                            const Divider(height: 24),
                            Text(content.isEmpty ? 'No post body found.' : content),
                          ],
                        ),
                      ),
                    ),
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
    final colors = <int>[Colors.blue.value, Colors.green.value, Colors.deepOrange.value];
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

  _ForumPost({required this.source, required this.raw, required this.key, required this.title, required this.author, required this.sortStamp});
}

class _ForumCalendarEntry {
  final ForumSource source;
  final String title;
  final String description;
  final DateTime start;
  final DateTime? end;
  final String url;

  _ForumCalendarEntry({required this.source, required this.title, required this.description, required this.start, required this.end, required this.url});
}

class _ForumPrivateMessage {
  final ForumSource source;
  final String title;
  final String sender;
  final String body;
  final int sortStamp;

  _ForumPrivateMessage({required this.source, required this.title, required this.sender, required this.body, required this.sortStamp});
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
