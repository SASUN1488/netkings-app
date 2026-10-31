import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'singbox.dart';

const _testUrl = 'https://www.gstatic.com/generate_204';

/// Live numbers from the running core (its clash API on localhost) and the protocol watchdog:
/// download / upload speed, ping through the tunnel, which server and protocol is in use.
/// When the ping fails twice in a row, the country group is re-tested (the core then moves to the best
/// working server / protocol); [onDead] is called when that does not help either.
/// After such a fallback [home] is the group the user picked: it is re-tested every minute and [onHome]
/// is called once it answers again.
class Monitor extends ChangeNotifier {
  final String secret;
  final bool autoSwitch;
  final void Function(String)? onSwitch;     // the watchdog moved off a dead server: "переключился на ..."
  final Future<void> Function()? onDead;     // nothing in this country answers
  final String? home;                        // e.g. "auto-fi" while the app runs on "auto" after a fallback
  final Future<void> Function()? onHome;     // [home] answers again
  final int port;
  final int proxyPort;
  Monitor(this.secret,
      {this.autoSwitch = true,
      this.onSwitch,
      this.onDead,
      this.home,
      this.onHome,
      this.port = clashPort,
      this.proxyPort = pingPort});

  int down = 0, up = 0;      // bytes per second
  int? ping;                 // ms of the last answer; null = none yet
  int misses = 0;            // rounds in a row without an answer; ping is stale while > 0
  String? leaf;              // e.g. "fi-relay3-grpc"
  bool _running = false;
  int _fails = 0, _deadRounds = 0, _rounds = 0;
  HttpClient? _http;
  _Tunnel? _tunnel;          // kept open between rounds through the core's ping proxy
  StreamSubscription? _traffic;
  Timer? _timer;

  void start() {
    if (_running) return;
    _running = true;
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    // the core needs a moment to open the API
    Future.delayed(const Duration(seconds: 2), () {
      if (!_running) return;
      _listenTraffic();
      tick();
      _timer = Timer.periodic(const Duration(seconds: 10), (_) => tick());
    });
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _traffic?.cancel();
    _http?.close(force: true);
    _http = null;
    _tunnel?.close();
    _tunnel = null;
    down = up = 0;
    ping = null;
    misses = 0;
    leaf = null;
    _fails = _deadRounds = _rounds = 0;
  }

  Future<dynamic> _get(String path, {Duration timeout = const Duration(seconds: 8)}) async {
    final h = _http;
    if (h == null) return null;
    final req = await h.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    final resp = await req.close().timeout(timeout);
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
    if (resp.statusCode != 200) throw HttpException('${resp.statusCode} $body');
    return jsonDecode(body);
  }

  /// /traffic streams one {"up":…, "down":…} line per second
  Future<void> _listenTraffic() async {
    try {
      final h = _http;
      if (h == null) return;
      final req = await h.getUrl(Uri.parse('http://127.0.0.1:$port/traffic'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      final resp = await req.close();
      _traffic = resp.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        try {
          final m = jsonDecode(l) as Map<String, dynamic>;
          down = (m['down'] as num).toInt();
          up = (m['up'] as num).toInt();
          notifyListeners();
        } on FormatException {
          // partial line
        }
      }, onDone: _retryTraffic, onError: (_) => _retryTraffic());
    } catch (_) {
      _retryTraffic();
    }
  }

  void _retryTraffic() {
    if (_running) Future.delayed(const Duration(seconds: 3), () => _running ? _listenTraffic() : null);
  }

  /// selector "proxy" -> country group -> leaf
  Future<(String?, String?)> _current() async {
    final group = (await _get('/proxies/proxy'))?['now'] as String?;
    if (group == null) return (null, null);
    final now = (await _get('/proxies/${Uri.encodeComponent(group)}'))?['now'] as String?;
    return (group, now ?? group);
  }

  /// Through the server in use itself: a failed test also makes the core forget that server's last result,
  /// so the group re-test below really checks it again (and leaves it).
  Future<int?> _ping(String? via) async {
    try {
      final r = await _get('/proxies/${Uri.encodeComponent(via ?? 'proxy')}/delay?url=${Uri.encodeComponent(_testUrl)}&timeout=5000');
      final d = (r?['delay'] as num?)?.toInt();
      return d != null && d > 0 ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// A single lost test (one dropped packet, the server's core restarting) is not a dead server: ask again.
  Future<int?> _pingTwice(String? via) async {
    final p = await _ping(via);
    if (p != null || _http == null) return p;
    await Future.delayed(retryDelay);
    return _ping(via);
  }

  /// The shown ping: one request over an already open connection through the server in use (one round trip
  /// phone -> entry -> exit -> site and back). The core's delay test above opens a new connection each time,
  /// so it also counts the TCP / REALITY / TLS handshakes (~3-4 round trips): right for "is it alive",
  /// too big for a number people compare with other VPNs. Plain HTTP inside the tunnel (the way to the exit
  /// is encrypted anyway) and our own socket: dart's HttpClient opens a new connection per request via a proxy.
  Future<int?> _rtt() async {
    for (var i = 0; i < 2; i++) {      // a kept tunnel may be dead (the core switched servers): one reconnect
      if (_http == null) return null;
      try {
        var t = _tunnel;
        if (t == null || t.closed) {
          t = _tunnel = await _Tunnel.open(proxyPort, 'nk', secret);
          await t.request();           // not timed: the exit only now connects to the site
        }
        final sw = Stopwatch()..start();
        await t.request();
        return sw.elapsedMilliseconds;
      } catch (_) {
        // no proxy (older core / tests) or a dropped tunnel: the delay test's number is shown instead
        _tunnel?.close();
        _tunnel = null;
      }
    }
    return null;
  }

  @visibleForTesting
  Duration retryDelay = const Duration(seconds: 1);

  @visibleForTesting
  void attach() => _http ??= HttpClient();

  @visibleForTesting
  Future<int?> rtt() => _rtt();

  /// Every 6th round (a minute) after a fallback: does the user's own pick answer again?
  Future<void> _checkHome(String? group) async {
    final h = home;
    if (h == null || group == h || ++_rounds % 6 != 0) return;
    try {
      final r = await _get('/group/${Uri.encodeComponent(h)}/delay?url=${Uri.encodeComponent(_testUrl)}&timeout=5000',
          timeout: const Duration(seconds: 15));
      if (r is Map && r.values.any((d) => d is num && d > 0) && _http != null) await onHome?.call();
    } catch (_) {
      // still dead
    }
  }

  /// One watchdog round (every 10 s while connected).
  @visibleForTesting
  Future<void> tick() async {
    if (_http == null) return;
    try {
      final (group, now) = await _current();
      final p = await _pingTwice(now);
      if (_http == null) return;
      if (p != null) ping = await _rtt() ?? p;
      if (_http == null) return;
      misses = p == null ? misses + 1 : 0;
      leaf = now ?? leaf;       // the core's own re-picks (a faster server) are not announced
      notifyListeners();
      if (p != null) {
        _fails = _deadRounds = 0;
        await _checkHome(group);
        return;
      }
      if (!autoSwitch || group == null || ++_fails < 2) return;
      // the server in use stopped answering: re-test the group now instead of waiting for its next round
      _fails = 0;
      await _get('/group/${Uri.encodeComponent(group)}/delay?url=${Uri.encodeComponent(_testUrl)}&timeout=5000',
              timeout: const Duration(seconds: 15))
          .catchError((_) => null);
      final (_, n) = await _current();
      final again = await _ping(n);
      if (again != null) {
        ping = await _rtt() ?? again;
        misses = 0;
        _deadRounds = 0;
        if (n != null && n != leaf) onSwitch?.call(n);
        leaf = n ?? leaf;
        notifyListeners();
      } else if (++_deadRounds >= 2) {
        _deadRounds = 0;
        await onDead?.call();
      }
    } catch (_) {
      // the core is restarting / not up yet
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// HTTP CONNECT tunnel to www.gstatic.com:80 through the core's local proxy, for repeated
/// `HEAD /generate_204` over one connection.
class _Tunnel {
  static const _host = 'www.gstatic.com';
  static const _timeout = Duration(seconds: 5);
  final Socket _s;
  final _buf = <int>[];
  Completer<void>? _more;
  bool closed = false;

  _Tunnel(this._s) {
    _s.listen((d) {
      _buf.addAll(d);
      _wake();
    }, onDone: close, onError: (_) => close(), cancelOnError: true);
  }

  static Future<_Tunnel> open(int port, String user, String password) async {
    final t = _Tunnel(await Socket.connect('127.0.0.1', port, timeout: _timeout));
    final auth = base64.encode(utf8.encode('$user:$password'));
    t._s.write('CONNECT $_host:80 HTTP/1.1\r\nHost: $_host:80\r\nProxy-Authorization: Basic $auth\r\n\r\n');
    final head = await t._head();
    if (!head.startsWith(RegExp(r'HTTP/1\.[01] 200'))) {
      t.close();
      throw HttpException('proxy: ${head.split('\r\n').first}');
    }
    return t;
  }

  /// One HEAD /generate_204; completes when the response head is in (204 has no body).
  Future<void> request() async {
    _s.write('HEAD /generate_204 HTTP/1.1\r\nHost: $_host\r\n\r\n');
    final head = await _head();
    if (!head.startsWith('HTTP/1.')) throw HttpException('bad answer');
    if (head.toLowerCase().contains('connection: close')) close();
  }

  /// The bytes up to the next empty line.
  Future<String> _head() async {
    while (true) {
      for (var i = 0; i + 3 < _buf.length; i++) {
        if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) {
          final h = latin1.decode(_buf.sublist(0, i));
          _buf.removeRange(0, i + 4);
          return h;
        }
      }
      if (closed) throw const SocketException('tunnel closed');
      _more = Completer();
      await _more!.future.timeout(_timeout);
    }
  }

  void _wake() {
    _more?.complete();
    _more = null;
  }

  void close() {
    if (closed) return;
    closed = true;
    _s.destroy();
    _wake();
  }
}

String formatSpeed(int bytesPerSec) {
  final bits = bytesPerSec * 8;
  if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(bits >= 10000000 ? 0 : 1)} Мбит/с';
  if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} Кбит/с';
  return '$bits бит/с';
}
