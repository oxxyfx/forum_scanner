import 'dart:async';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as sio;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:html/parser.dart' as html_parser;
import 'forum_source.dart';

class SmfService {
  final ForumSource source;
  late final Dio _dio;
  late final CookieJar _cookieJar;
  String? _csrfToken;

  SmfService({required this.source}) {
    _dio = Dio();
    _cookieJar = CookieJar();
    _dio.interceptors.add(CookieManager(_cookieJar));

    _dio.options.headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Origin': source.baseUrl.trim(),
      'Referer': '${source.baseUrl.trim()}/login',
    };
  }

  String get _cleanBaseUrl {
    String cleanBaseUrl = source.baseUrl.trim();
    if (cleanBaseUrl.endsWith('/')) {
      cleanBaseUrl = cleanBaseUrl.substring(0, cleanBaseUrl.length - 1);
    }
    return cleanBaseUrl;
  }

  Future<bool> login() async {
    try {
      final loginUrl = '$_cleanBaseUrl/login';

      print('--- DIAGNOSTIC RUN START ---');
      print('Stage 1: Requesting login layout from: $loginUrl');
      final preFlightResponse = await _dio.get(loginUrl);

      final document = html_parser.parse(preFlightResponse.data);
      String? csrfTokenValue;

      final inputElement = document.querySelector('input[name="_csrf"]');
      if (inputElement != null) {
        csrfTokenValue = inputElement.attributes['value'];
      }

      _csrfToken = csrfTokenValue ?? _extractCsrfToken(preFlightResponse.data.toString());
      csrfTokenValue = _csrfToken;

      print('Stage 2: Extracted NodeBB CSRF Token: $csrfTokenValue');

      // Build standard NodeBB JSON payload
      final Map<String, dynamic> loginPayload = {
        'username': source.username.trim(),
        'password': source.password,
        'remember': true,
      };

      final Options postOptions = Options(
        contentType: Headers.jsonContentType, // Switch to pure JSON
        followRedirects: true,
        validateStatus: (int? status) => status != null && status < 600,
      );

      if (csrfTokenValue != null) {
        postOptions.headers = {
          'x-csrf-token': csrfTokenValue,
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': loginUrl,
        };
      }

      print('Stage 3: Submitting JSON payload to server endpoint...');
      final response = await _dio.post(
        loginUrl,
        data: loginPayload,
        options: postOptions,
      );

      final finalCookies = await _cookieJar.loadForRequest(Uri.parse(_cleanBaseUrl));
      print('DEBUG [HTTP Status Code Received]: ${response.statusCode}');

      if ((response.statusCode == 200 || response.statusCode == 302) && finalCookies.isNotEmpty) {
        if (!response.data.toString().contains('error:invalid-username-or-password')) {
          print('Identity Map successfully validated against platform specifications!');
          return true;
        }
      }

      print('Authentication failed.');
      return false;
    } catch (e, stacktrace) {
      print('CRITICAL EXCEPTION OCCURRED: $e');
      print('STACKTRACE: $stacktrace');
      return false;
    }
  }

  Future<Map<String, dynamic>?> fetchUnreadTopics() async {
    try {
      final unreadApiUrl = '$_cleanBaseUrl/api/unread';
      print('Pulling active unread data feed array from: $unreadApiUrl');

      var response = await _dio.get(unreadApiUrl);

      if (response.statusCode == 200) {
        final unwrapped = _unwrapResponse(response.data);
        if (unwrapped is Map) {
          Map<String, dynamic> data = Map<String, dynamic>.from(unwrapped);

          if (data.containsKey('posts') && !data.containsKey('topics')) {
            data['topics'] = data['posts'];
          }

          if (data['topics'] is List && (data['topics'] as List).isNotEmpty) {
            return data;
          }
        }
      }

      final recentApiUrl = '$_cleanBaseUrl/api/recent';
      print('Unread tray empty or unparsed. Loading active stream fallback from: $recentApiUrl');

      var recentResponse = await _dio.get(recentApiUrl);
      if (recentResponse.statusCode == 200) {
        final unwrapped = _unwrapResponse(recentResponse.data);
        if (unwrapped is Map) {
          Map<String, dynamic> recentData = Map<String, dynamic>.from(unwrapped);

          if (recentData.containsKey('posts') && !recentData.containsKey('topics')) {
            recentData['topics'] = recentData['posts'];
          }
          return recentData;
        }
      }

      return null;
    } catch (e) {
      print('Error pulling data stream: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchTopicDetails(Map<String, dynamic> topic) async {
    try {
      final dynamic rawTid = topic['tid'] ?? topic['topic']?['tid'];
      final dynamic rawPid = topic['pid'];

      if (rawTid == null) {
        final fallbackContent = _plainText(
          topic['content']?.toString() ?? 'No post body was included in this forum feed item.',
        );
        return {
          'title': _decodeHtmlText((topic['title'] ?? 'Forum Post').toString()),
          'author': _decodeHtmlText((topic['user']?['username'] ?? 'Anonymous').toString()),
          'content': fallbackContent,
          'posts': [
            {
              'author': _decodeHtmlText((topic['user']?['username'] ?? 'Anonymous').toString()),
              'content': fallbackContent,
              'htmlContent': topic['content']?.toString() ?? fallbackContent,
              'timestamp': topic['timestamp'],
            }
          ],
          'url': topic['url']?.toString() ?? '',
        };
      }

      final String tid = rawTid.toString();
      final String topicApiUrl = '$_cleanBaseUrl/api/topic/$tid';
      print('Loading full topic thread from: $topicApiUrl');

      final response = await _dio.get(
        topicApiUrl,
        options: Options(validateStatus: (status) => status != null && status < 600),
      );
      if (response.statusCode != 200) {
        print('Topic detail failed with status ${response.statusCode}: ${response.data}');
        return null;
      }

      final unwrapped = _unwrapResponse(response.data);
      if (unwrapped is! Map) {
        print('Topic detail failed: unwrapped data is not a Map');
        return null;
      }
      final data = Map<String, dynamic>.from(unwrapped);
      final List rawPosts = data['posts'] is List ? data['posts'] as List : [];

      final threadPosts = <Map<String, dynamic>>[];
      for (final rawPost in rawPosts) {
        if (rawPost is! Map) continue;
        final post = Map<String, dynamic>.from(rawPost);
        final user = post['user'];
        String author = 'Anonymous';
        if (user is Map && user['username'] != null) {
          author = user['username'].toString();
        } else if (post['username'] != null) {
          author = post['username'].toString();
        }

        final rawContent = _stripCalendarTags(post['content']?.toString() ?? '');
        final content = _plainText(rawContent);
        if (content.trim().isEmpty && rawContent.trim().isEmpty) continue;

        threadPosts.add({
          'pid': post['pid'],
          'author': author,
          'content': content,
          'htmlContent': rawContent,
          'timestamp': post['timestamp'] ?? post['edited'] ?? post['timestampISO'],
          'index': post['index'],
        });
      }

      if (rawPid != null && threadPosts.length > 1) {
        final selectedIndex = threadPosts.indexWhere((p) => p['pid']?.toString() == rawPid.toString());
        if (selectedIndex > 0) {
          final selected = threadPosts.removeAt(selectedIndex);
          threadPosts.insert(0, selected);
        }
      }

      final String title = data['title']?.toString() ?? topic['title']?.toString() ?? 'Forum Post';
      final String firstAuthor = threadPosts.isNotEmpty
          ? threadPosts.first['author'].toString()
          : (topic['user']?['username']?.toString() ?? 'Anonymous');
      final String firstContent = threadPosts.isNotEmpty
          ? threadPosts.first['content'].toString()
          : _plainText(topic['content']?.toString() ?? 'No post body was found for this topic.');

      return {
        'title': title,
        'author': firstAuthor,
        'content': firstContent,
        'posts': threadPosts.isNotEmpty
            ? threadPosts
            : [
                {
                  'author': firstAuthor,
                  'content': firstContent,
                  'htmlContent': topic['content']?.toString() ?? firstContent,
                  'timestamp': topic['timestamp'],
                }
              ],
        'url': '$_cleanBaseUrl/topic/$tid',
      };
    } catch (e, stacktrace) {
      print('Error loading topic details: $e');
      print('Topic detail stacktrace: $stacktrace');
      return null;
    }
  }

  /// Strip NodeBB plugin-calendar template tags from raw HTML/text content.
  String _stripCalendarTags(String html) {
    var out = html;

    // [[moment:time-date-view, local, startMs, endMs, allDay]]
    // → replace with a human-readable date/time string
    out = out.replaceAllMapped(
      RegExp(r'\[\[moment:time-date-view,\s*local,\s*(\d+),\s*(\d+),\s*(true|false)\]\]',
             caseSensitive: false),
      (m) {
        final startMs = int.tryParse(m.group(1) ?? '0') ?? 0;
        final endMs   = int.tryParse(m.group(2) ?? '0') ?? 0;
        final allDay  = m.group(3) == 'true';
        final start = DateTime.fromMillisecondsSinceEpoch(startMs);
        final end   = DateTime.fromMillisecondsSinceEpoch(endMs);
        const months = ['Jan','Feb','Mar','Apr','May','Jun',
                        'Jul','Aug','Sep','Oct','Nov','Dec'];
        const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
        final dayName   = days[start.weekday - 1];
        final monthName = months[start.month - 1];
        if (allDay) {
          return '$dayName $monthName ${start.day} ${start.year}';
        }
        String _t(DateTime dt) =>
            '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
        return '$dayName $monthName ${start.day} ${start.year}, ${_t(start)} – ${_t(end)}';
      },
    );

    // [[calendar:response_yes/no/maybe]] — response buttons, strip entirely
    out = out.replaceAll(
      RegExp(r'\[\[calendar:response_(?:yes|no|maybe)\]\]', caseSensitive: false), '');

    // plugin-calendar-event-wrapper:start |||Title||| and :end lines
    out = out.replaceAll(
      RegExp(r'plugin-calendar-event-wrapper:\w+[^\n]*', caseSensitive: false), '');

    // Any remaining [[...]] NodeBB template tags
    out = out.replaceAll(RegExp(r'\[\[[^\]]*\]\]'), '');

    // Clean up extra blank lines left behind (plain text)
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return out;
  }

  String _plainText(String htmlText) {
    final cleaned = _stripCalendarTags(htmlText);
    final document = html_parser.parse(cleaned);
    return document.body?.text.trim() ?? cleaned.trim();
  }

  String _decodeHtmlText(String value) {
    if (value.trim().isEmpty) return value;
    return html_parser.parseFragment(value).text?.trim() ?? value;
  }

  String? _extractCsrfToken(String text) {
    final patterns = <RegExp>[
      RegExp(r'''csrf_token\s*[:=]\s*["']([^"']+)["']'''),
      RegExp(r'''_csrf\s*[:=]\s*["']([^"']+)["']'''),
      RegExp(r'"csrf_token"\s*:\s*"([^"]+)"'),
      RegExp(r'"csrf"\s*:\s*"([^"]+)"'),
      RegExp(r'''name=["']_csrf["'][^>]*value=["']([^"']+)["']'''),
      RegExp(r'''value=["']([^"']+)["'][^>]*name=["']_csrf["']'''),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.groupCount >= 1) {
        final value = match.group(1)?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  String _topicUrlFromTopic(Map<String, dynamic> topic, String tid) {
    final rawUrl = topic['url']?.toString();
    if (rawUrl != null && rawUrl.isNotEmpty) {
      return rawUrl.startsWith('http') ? rawUrl : '$_cleanBaseUrl$rawUrl';
    }

    final slug = topic['slug']?.toString() ?? topic['topic']?['slug']?.toString();
    if (slug != null && slug.isNotEmpty) {
      return '$_cleanBaseUrl/topic/$slug';
    }

    return '$_cleanBaseUrl/topic/$tid';
  }

  dynamic _unwrapResponse(dynamic data) {
    if (data == null) return null;
    if (data is String && data.trim().startsWith('{')) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      if (map.containsKey('response')) {
        return map['response'];
      }
    }
    return data;
  }

  Future<String?> _refreshCsrfToken({String path = '/'}) async {
    try {
      final configResponse = await _dio.get(
        '$_cleanBaseUrl/api/config',
        options: Options(validateStatus: (status) => status != null && status < 600),
      );

      if (configResponse.data is Map) {
        final data = Map<String, dynamic>.from(configResponse.data as Map);
        final token = (data['csrf_token'] ?? data['csrfToken'] ?? data['csrf'])?.toString();
        if (token != null && token.isNotEmpty) {
          _csrfToken = token;
          return token;
        }
      }

      final pageResponse = await _dio.get(
        '$_cleanBaseUrl$path',
        options: Options(validateStatus: (status) => status != null && status < 600),
      );
      final token = pageResponse.headers.value('x-csrf-token') ?? _extractCsrfToken(pageResponse.data.toString());
      if (token != null && token.isNotEmpty) {
        _csrfToken = token;
        return token;
      }
    } catch (e) {
      print('CSRF refresh failed: $e');
    }
    return _csrfToken;
  }

  Future<List<Map<String, dynamic>>> fetchCalendarEvents() async {
    final now = DateTime.now();
    final rangeStart = DateTime(now.year, now.month, 1);
    final rangeEnd   = DateTime(now.year, now.month + 3, 1);

    // Build month ranges: current month + next 2
    final ranges = <(int, int)>[];
    for (int i = 0; i <= 2; i++) {
      final s = DateTime(now.year, now.month + i, 1);
      final e = DateTime(now.year, now.month + i + 1, 1);
      ranges.add((s.millisecondsSinceEpoch, e.millisecondsSinceEpoch));
    }

    // Single socket connection; all month requests sent in parallel
    final rawEvents = await _fetchCalendarEventsMultiMonth(ranges);

    if (rawEvents.isNotEmpty) {
      // Deduplicate by pid+startDate.
      // Recurring event instances share the same pid but have different startDates —
      // deduplicating by pid alone would collapse them all into one entry.
      final seen = <String>{};
      final uniqueRaw = <Map<String, dynamic>>[];
      for (final e in rawEvents) {
        final pid    = e['pid']?.toString() ?? '';
        final startMs = (e['startDate'] ?? e['start'] ?? '').toString();
        final dedupeKey = pid.isNotEmpty ? '$pid:$startMs' : '${startMs}:${e['name']}';
        if (seen.add(dedupeKey)) uniqueRaw.add(e);
      }
      print('Calendar: ${rawEvents.length} raw → ${uniqueRaw.length} unique for ${source.name}');

      // Expand recurring events into individual instances within the display range
      final expanded = <Map<String, dynamic>>[];
      for (final e in uniqueRaw) {
        expanded.addAll(_expandRepeatingEvent(e, rangeStart, rangeEnd));
      }

      expanded.sort((a, b) => (_dateFromAny(a['start']) ?? DateTime(0))
          .compareTo(_dateFromAny(b['start']) ?? DateTime(0)));
      print('Calendar: ${expanded.length} after expansion for ${source.name}');
      return expanded;
    }

    // REST fallback
    try {
      final startIso = rangeStart.toUtc().toIso8601String();
      final endIso   = rangeEnd.toUtc().toIso8601String();
      final response = await _dio.get(
        '$_cleanBaseUrl/api/v3/plugins/calendar/events',
        queryParameters: {'startDate': startIso, 'endDate': endIso},
        options: Options(
          headers: {'X-Requested-With': 'XMLHttpRequest'},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      print('Calendar REST status: ${response.statusCode}');
      if (response.statusCode == 200) {
        final unwrapped = _unwrapResponse(response.data);
        List? eventList;
        if (unwrapped is Map) {
          final m = Map<String, dynamic>.from(unwrapped);
          eventList = (m['events'] ?? m['data'] ?? m['results']) as List?;
          if (eventList == null && m.values.whereType<List>().isNotEmpty) {
            eventList = m.values.whereType<List>().first;
          }
        } else if (unwrapped is List) {
          eventList = unwrapped;
        }
        if (eventList != null && eventList.isNotEmpty) {
          final results = eventList.whereType<Map>()
              .map((e) => _normalizeEvent(Map<String, dynamic>.from(e)))
              .toList();
          results.sort((a, b) => (_dateFromAny(a['startDate']) ?? DateTime(0))
              .compareTo(_dateFromAny(b['startDate']) ?? DateTime(0)));
          print('Calendar REST found ${results.length} for ${source.name}.');
          return results;
        }
      }
    } catch (e) {
      print('Calendar REST fallback failed: $e');
    }

    print('Calendar found 0 events for ${source.name}.');
    return [];
  }

  /// Opens ONE socket connection to this forum and sends all month requests in
  /// parallel. Returns raw (un-normalized) event maps so the caller can
  /// deduplicate and expand recurring events before normalizing.
  Future<List<Map<String, dynamic>>> _fetchCalendarEventsMultiMonth(
      List<(int, int)> ranges) async {
    final cookies = await _cookieJar.loadForRequest(Uri.parse(_cleanBaseUrl));
    final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');

    final completers = <Completer<List<Map<String, dynamic>>>>[];
    final connectCompleter = Completer<void>();

    final socket = sio.io(
      _cleanBaseUrl,
      sio.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setExtraHeaders({'Cookie': cookieStr})
          .disableAutoConnect()
          .setTimeout(10000)
          .build(),
    );

    socket.onConnect((_) {
      print('Calendar socket connected to ${source.name}, sending ${ranges.length} parallel requests');
      for (int i = 0; i < ranges.length; i++) {
        final c = Completer<List<Map<String, dynamic>>>();
        completers.add(c);
        final range = ranges[i];
        final idx = i;
        socket.emitWithAck(
          'plugins.calendar.getEventsByDate',
          [{'startDate': range.$1, 'endDate': range.$2}],
          ack: (dynamic raw) {
            if (c.isCompleted) return;
            dynamic payload = raw;
            if (raw is List) {
              if (raw.length >= 2) {
                if (raw[0] != null) { c.complete([]); return; }
                payload = raw[1];
              } else if (raw.length == 1) {
                payload = raw[0];
              }
            }
            List<dynamic> eventList = [];
            if (payload is List) {
              eventList = payload;
            } else if (payload is Map && payload['events'] is List) {
              eventList = payload['events'] as List;
            }
            final events = eventList.whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e as Map)).toList();
            print('Calendar month $idx (${source.name}): ${events.length} raw events');
            c.complete(events);
          },
        );
      }
      Future.wait(completers.map((c) => c.future)).then((_) {
        socket.disconnect();
        if (!connectCompleter.isCompleted) connectCompleter.complete();
      });
    });

    socket.onConnectError((e) {
      print('Calendar socket connect error (${source.name}): $e');
      for (final c in completers) {
        if (!c.isCompleted) c.complete([]);
      }
      socket.disconnect();
      if (!connectCompleter.isCompleted) connectCompleter.complete();
    });

    socket.onError((e) => print('Calendar socket error (${source.name}): $e'));

    socket.connect();

    try {
      await connectCompleter.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      print('Calendar socket timeout for ${source.name}');
      for (final c in completers) {
        if (!c.isCompleted) c.complete([]);
      }
    }
    socket.disconnect();

    final allEvents = <Map<String, dynamic>>[];
    for (final c in completers) {
      if (c.isCompleted) {
        try { allEvents.addAll(await c.future); } catch (_) {}
      }
    }
    return allEvents;
  }

  /// Expand a single raw event (with optional `repeats` field) into normalized
  /// instances that fall within [rangeStart, rangeEnd).
  /// Non-recurring events return one normalized entry.
  List<Map<String, dynamic>> _expandRepeatingEvent(
      Map<String, dynamic> rawEvent, DateTime rangeStart, DateTime rangeEnd) {
    final originalStart = _dateFromAny(rawEvent['startDate'] ?? rawEvent['start']);
    if (originalStart == null) return [_normalizeEvent(rawEvent)];

    final repeats = rawEvent['repeats'];
    if (repeats == null || repeats is! Map || (repeats as Map).isEmpty) {
      return [_normalizeEvent(rawEvent)];
    }

    final repeatsMap = Map<String, dynamic>.from(repeats as Map);
    final every = repeatsMap['every'];
    if (every == null || every is! Map) return [_normalizeEvent(rawEvent)];

    final everyMap = Map<String, dynamic>.from(every as Map);
    final unit  = everyMap['unit']?.toString() ?? '';
    final value = (everyMap['value'] as num?)?.toInt() ?? 1;

    final originalEnd = _dateFromAny(rawEvent['endDate'] ?? rawEvent['end']);
    final duration = (originalEnd != null && originalEnd.isAfter(originalStart))
        ? originalEnd.difference(originalStart)
        : const Duration(hours: 1);

    final repeatEnd  = _dateFromAny(repeatsMap['endDate']);
    final effectiveEnd = (repeatEnd != null && repeatEnd.isBefore(rangeEnd))
        ? repeatEnd.add(const Duration(days: 1))
        : rangeEnd;

    final instances = <Map<String, dynamic>>[];

    Map<String, dynamic> _instance(DateTime instanceStart) => _normalizeEvent({
          ...rawEvent,
          'startDate': instanceStart.millisecondsSinceEpoch,
          'endDate': instanceStart.add(duration).millisecondsSinceEpoch,
        });

    if (unit == 'week') {
      // NodeBB days: numeric keys "0"–"6" (0=Sun) or named "sun"/"mon"/…
      // Dart weekday: 1=Mon … 6=Sat, 7=Sun
      const numToDart  = {0: 7, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6};
      const nameToDart = {'sun': 7, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

      final daysObj   = repeatsMap['days'];
      final activeDays = <int>{};
      if (daysObj is Map) {
        for (final entry in (daysObj as Map).entries) {
          if (entry.value == true) {
            final k = entry.key.toString();
            final n = int.tryParse(k);
            final d = n != null ? numToDart[n] : nameToDart[k.toLowerCase()];
            if (d != null) activeDays.add(d);
          }
        }
      }
      if (activeDays.isEmpty) activeDays.add(originalStart.weekday);

      if (value == 1) {
        // Every week: iterate day-by-day through range
        var cur = rangeStart;
        while (cur.isBefore(effectiveEnd)) {
          if (activeDays.contains(cur.weekday)) {
            instances.add(_instance(DateTime(cur.year, cur.month, cur.day,
                originalStart.hour, originalStart.minute, originalStart.second)));
          }
          cur = cur.add(const Duration(days: 1));
        }
      } else {
        // Every N weeks: seed from originalStart, advance in N-week steps
        for (final dartDay in activeDays) {
          var seed = originalStart;
          while (seed.weekday != dartDay) seed = seed.add(const Duration(days: 1));
          seed = DateTime(seed.year, seed.month, seed.day,
              originalStart.hour, originalStart.minute, originalStart.second);
          while (seed.isBefore(rangeStart)) seed = seed.add(Duration(days: 7 * value));
          while (seed.isBefore(effectiveEnd)) {
            instances.add(_instance(seed));
            seed = seed.add(Duration(days: 7 * value));
          }
        }
      }
    } else if (unit == 'day') {
      var candidate = originalStart;
      if (candidate.isBefore(rangeStart)) {
        final diff  = rangeStart.difference(candidate).inDays;
        final jumps = (diff / value).ceil();
        candidate   = candidate.add(Duration(days: jumps * value));
      }
      while (candidate.isBefore(effectiveEnd)) {
        instances.add(_instance(candidate));
        candidate = candidate.add(Duration(days: value));
      }
    } else if (unit == 'month') {
      var candidate = originalStart;
      while (candidate.isBefore(rangeStart)) {
        var m = candidate.month + value;
        var y = candidate.year + (m - 1) ~/ 12;
        m = ((m - 1) % 12) + 1;
        candidate = DateTime(y, m, originalStart.day,
            originalStart.hour, originalStart.minute, originalStart.second);
      }
      while (candidate.isBefore(effectiveEnd)) {
        instances.add(_instance(candidate));
        var m = candidate.month + value;
        var y = candidate.year + (m - 1) ~/ 12;
        m = ((m - 1) % 12) + 1;
        candidate = DateTime(y, m, originalStart.day,
            originalStart.hour, originalStart.minute, originalStart.second);
      }
    } else {
      return [_normalizeEvent(rawEvent)];
    }

    if (instances.isEmpty) {
      // Recurrence has no instances in range — still show original if it falls in range
      final norm = _normalizeEvent(rawEvent);
      final s = _dateFromAny(norm['start']);
      if (s != null && !s.isBefore(rangeStart) && s.isBefore(rangeEnd)) return [norm];
      return [];
    }
    return instances;
  }

  Map<String, dynamic> _normalizeEvent(Map<String, dynamic> event) {
    final pid = event['pid']?.toString();
    return {
      ...event,
      'pid': pid,
      'title': event['name'] ?? event['title'] ?? 'Calendar Entry',
      'description': _plainText(event['description']?.toString() ?? ''),
      'location': _plainText(event['location']?.toString() ?? ''),
      'start': _dateFromAny(event['startDate'] ?? event['start'])?.toIso8601String(),
      'end': _dateFromAny(event['endDate'] ?? event['end'])?.toIso8601String(),
      'url': event['url'] ?? (pid != null ? '$_cleanBaseUrl/calendar/event/$pid' : null),
    };
  }

  Future<Map<String, dynamic>?> _fetchCalendarEventByPid(String pid) async {
    try {
      final response = await _dio.get(
        '$_cleanBaseUrl/api/calendar/event/$pid',
        options: Options(
          headers: {'X-Requested-With': 'XMLHttpRequest'},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      if (response.statusCode != 200) return null;
      final unwrapped = _unwrapResponse(response.data);
      if (unwrapped is! Map) return null;
      final data = Map<String, dynamic>.from(unwrapped);
      Map<String, dynamic>? event;
      if (data['eventData'] is Map) {
        event = Map<String, dynamic>.from(data['eventData'] as Map);
      } else if (data['eventJSON'] != null && data['eventJSON'].toString().trim() != 'null') {
        try {
          final decoded = data['eventJSON'] is String
              ? jsonDecode(data['eventJSON'] as String)
              : data['eventJSON'];
          if (decoded is Map) event = Map<String, dynamic>.from(decoded);
        } catch (_) {}
      }
      if (event == null) return null;
      event['pid'] = event['pid'] ?? pid;
      return _normalizeEvent(event);
    } catch (e) {
      print('Calendar event $pid fetch failed: $e');
      return null;
    }
  }

    DateTime? _dateFromAny(dynamic value) {
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

  Future<List<Map<String, dynamic>>> fetchPrivateMessageThread(String roomId) async {
    try {
      final response = await _dio.get(
        '$_cleanBaseUrl/api/v3/chats/$roomId',
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'Accept': 'application/json',
            if (_csrfToken != null && _csrfToken!.isNotEmpty) 'x-csrf-token': _csrfToken,
          },
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      if (response.statusCode != 200 || response.data == null) {
        return [];
      }

      final unwrapped = _unwrapResponse(response.data);
      if (unwrapped is! Map) {
        return [];
      }

      final data = Map<String, dynamic>.from(unwrapped);
      final rawMessages = data['messages'] ?? data['posts'] ?? data['chatMessages'];

      if (rawMessages is! List) {
        return [];
      }

      final messages = <Map<String, dynamic>>[];

      for (final raw in rawMessages) {
        if (raw is! Map) continue;
        final msg = Map<String, dynamic>.from(raw);

        String sender = 'Unknown';
        final fromUser = msg['fromUser'] ?? msg['user'];
        if (fromUser is Map && fromUser['username'] != null) {
          sender = fromUser['username'].toString();
        } else if (msg['username'] != null) {
          sender = msg['username'].toString();
        }

        messages.add({
          'sender': sender,
          'body': msg['content'] ?? '',
          'timestamp': msg['timestamp'] ?? msg['timestampISO'],
          'type': msg['type'] ?? '',
          'system': msg['system'] ?? false,
        });
      }

      messages.sort((a, b) {
        final aTs = int.tryParse((a['timestamp'] ?? 0).toString()) ?? 0;
        final bTs = int.tryParse((b['timestamp'] ?? 0).toString()) ?? 0;
        return aTs.compareTo(bTs);
      });

      return messages;
    } catch (e, stacktrace) {
      print('Error loading PM thread for room $roomId: $e');
      print(stacktrace);
      return [];
    }
  }


  Future<bool> sendChatMessage(String roomId, String message) async {
    try {
      final csrf = await _refreshCsrfToken();

      // Try /messages endpoint first (NodeBB v3), fall back to room endpoint
      final endpoints = [
        '$_cleanBaseUrl/api/v3/chats/$roomId/messages',
        '$_cleanBaseUrl/api/v3/chats/$roomId',
      ];

      for (final url in endpoints) {
        final response = await _dio.post(
          url,
          data: {'message': message},
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.json,
            headers: {
              'Accept': 'application/json',
              'X-Requested-With': 'XMLHttpRequest',
              if (csrf != null && csrf.isNotEmpty) 'x-csrf-token': csrf,
            },
            validateStatus: (status) => status != null && status < 600,
          ),
        );
        print('Send PM [$url] status: ${response.statusCode}');
        print('Send PM response: ${response.data}');
        if (response.statusCode != null &&
            response.statusCode! >= 200 &&
            response.statusCode! < 300) {
          return true;
        }
      }
      return false;
    } catch (e, st) {
      print('Send PM failed: $e');
      print('Send PM stacktrace: $st');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> fetchPrivateMessages() async {
    try {
      String cleanBaseUrl = source.baseUrl.trim();
      if (cleanBaseUrl.endsWith('/')) {
        cleanBaseUrl = cleanBaseUrl.substring(0, cleanBaseUrl.length - 1);
      }

      print('Fetching NodeBB Private Messages from: $cleanBaseUrl/api/v3/chats');

      // Fetch the dedicated NodeBB chat rooms endpoint
      final response = await _dio.get(
        '$cleanBaseUrl/api/v3/chats',
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'Accept': 'application/json',
            if (_csrfToken != null && _csrfToken!.isNotEmpty) 'x-csrf-token': _csrfToken,
          },
        ),
      );

      print('NodeBB Chats API Status: ${response.statusCode}');
      print('NodeBB Chats API Data Type: ${response.data.runtimeType}');
      print('NodeBB Chats API Raw Body: ${response.data}');

      List<Map<String, dynamic>> parsedMessages = [];

      if (response.statusCode == 200 && response.data != null) {
        final unwrapped = _unwrapResponse(response.data);
        final data = unwrapped is Map<String, dynamic>
            ? unwrapped
            : Map<String, dynamic>.from(unwrapped as Map);

        var roomsList = data['rooms'] ?? data['chats'] ?? data['data'] ?? data['results'];

        if (roomsList is List) {
          for (final room in roomsList) {

            // Parse Room title or group names
            String roomTitle = room['roomName'] ?? '';

            // Parse last message snippet
            final lastMessage = room['teaser'] ?? room['lastMessage'];
            String bodySnippet = 'No messages in this chat';
            int timestamp = DateTime.now().millisecondsSinceEpoch;

            if (lastMessage is Map) {
              bodySnippet = (lastMessage['content'] ?? 'No text preview').toString();
              timestamp = int.tryParse((lastMessage['timestamp'] ?? timestamp).toString()) ?? timestamp;
            } else if (lastMessage is String && lastMessage.trim().isNotEmpty) {
              bodySnippet = lastMessage.trim();
            }


            // Parse sending participant info — try multiple sources
            String senderName = '';

            // 1. users list
            if (room['users'] is List) {
              for (final u in (room['users'] as List)) {
                if (u is Map) {
                  final name = (u['username'] ?? u['displayname'] ?? '').toString().trim();
                  if (name.isNotEmpty) { senderName = name; break; }
                }
              }
            }
            // 2. room['user']
            if (senderName.isEmpty && room['user'] is Map) {
              senderName = (room['user']['username'] ?? room['user']['displayname'] ?? '').toString().trim();
            }
            // 3. teaser / last message user
            if (senderName.isEmpty && lastMessage is Map) {
              final tu = lastMessage['user'] ?? lastMessage['fromUser'];
              if (tu is Map) {
                senderName = (tu['username'] ?? tu['displayname'] ?? '').toString().trim();
              }
            }
            // 4. owner field
            if (senderName.isEmpty && room['owner'] is Map) {
              senderName = (room['owner']['username'] ?? '').toString().trim();
            }
            if (senderName.isEmpty) senderName = 'Unknown';

            // Fallback title if it's a direct one-on-one message with no room title
            if (roomTitle.trim().isEmpty) {
              roomTitle = 'Chat with $senderName';
            }

            parsedMessages.add({
              'roomId': room['roomId'],
              'title': roomTitle,
              'sender': senderName,
              'body': bodySnippet,
              'timestamp': timestamp,
            });

          }
        }
      }

      // If API responded but you literally have no active group/private chats opened
      if (parsedMessages.isEmpty) {
        print('PM discovery: no chat rooms returned for ${source.name}');
        return [];
      }

      return parsedMessages;

    } catch (e, stacktrace) {
      print('Error parsing NodeBB chats for ${source.name}: $e');
      print(stacktrace);
      return [];
    }
  }

  Future<bool> replyToTopic(Map<String, dynamic> topic, String message) async {
    try {
      final dynamic rawTid = topic['tid'] ?? topic['topic']?['tid'];
      if (rawTid == null) {
        print('Reply failed: topic does not include tid. Topic keys: ${topic.keys.toList()}');
        return false;
      }

      final String tid = rawTid.toString();
      final String topicUrl = _topicUrlFromTopic(topic, tid);

      final csrf = await _refreshCsrfToken(path: Uri.parse(topicUrl).path);

      final payload = <String, dynamic>{
        'uuid': DateTime.now().microsecondsSinceEpoch.toString(),
        'tid': int.tryParse(tid) ?? tid,
        'content': message,
        'toPid': null,
      };

      final response = await _dio.post(
        '$_cleanBaseUrl/api/v3/topics/$tid',
        data: payload,
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          headers: {
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'Origin': _cleanBaseUrl,
            'Referer': topicUrl,
            'X-Requested-With': 'XMLHttpRequest',
            if (csrf != null && csrf.isNotEmpty) 'x-csrf-token': csrf,
          },
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      print('Reply endpoint: $_cleanBaseUrl/api/v3/topics/$tid');
      print('Reply status: ${response.statusCode}');
      print('Reply response: ${response.data}');

      final body = response.data.toString().toLowerCase();
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300 &&
          !body.contains('invalid csrf') &&
          !body.contains('not-authorized') &&
          !body.contains('not authorized') &&
          !body.contains('forbidden') &&
          !body.contains('error');
    } catch (e, stacktrace) {
      print('Reply failed: $e');
      print('Reply stacktrace: $stacktrace');
      return false;
    }
  }
}
