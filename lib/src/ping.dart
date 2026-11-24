import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Ways to measure the ping, Настройки → Пинг. "direct" ones go straight to the server (also before
/// connecting; while connected the core sends entry addresses around the tunnel), the others through the VPN.
const pingMethods = <String, (String, String)>{
  'nk': ('NK Ping', 'Наш способ: общий пинг и из чего он состоит — до сервера + дальше по VPN'),
  'tcp': ('TCP', 'Время соединения с сервером. Работает и до подключения'),
  'icmp': ('ICMP', 'Классический ping до сервера. Работает и до подключения'),
  'head': ('HTTP HEAD', 'Запрос к сайту через VPN, каждый раз с новым соединением'),
  'get': ('HTTP GET', 'Как HEAD, но с полным ответом сайта'),
};

/// Methods that do not need the VPN: the server list can show them before connecting.
bool isDirectPing(String method) => method == 'tcp' || method == 'icmp';

/// What the stats bar shows: the total, and for NK Ping its parts.
class PingResult {
  final int total;
  final int? toServer; // NK Ping: phone -> entry server (one TCP handshake, outside the tunnel)
  const PingResult(this.total, [this.toServer]);

  /// NK Ping: entry -> exit -> the site and back (what the VPN itself adds).
  int? get beyond => toServer == null ? null : (total - toServer!).clamp(0, total);
}

/// Middle value: one slow sample (a retransmit) does not move it, unlike the average.
int median(List<int> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// TCP connect time to [host]:[port]: one round trip (SYN -> SYN/ACK).
Future<int?> tcpPing(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    final ms = sw.elapsedMilliseconds;
    s.destroy();
    return ms;
  } catch (_) {
    return null;
  }
}

/// TCP ping [n] times, the median of the answers (null = none answered); [best] = the fastest one instead:
/// the bare latency of the way, without the random queueing delays of a busy link.
Future<int?> tcpPingMedian(String host, int port, {int n = 3, bool best = false}) async {
  final r = <int>[];
  for (var i = 0; i < n; i++) {
    final p = await tcpPing(host, port);
    if (p != null) r.add(p);
  }
  if (r.isEmpty) return null;
  return best ? r.reduce(min) : median(r);
}

/// "time=12.3 ms", Windows "время=12мс" / "time<1ms": every reply's time in ms.
List<int> parsePingTimes(String out) => [
  for (final m in RegExp(r'[=<]\s*(\d+(?:[.,]\d+)?)\s*(?:ms|мс)', caseSensitive: false).allMatches(out))
    double.parse(m.group(1)!.replaceAll(',', '.')).round(),
];

/// ICMP echo through the system's ping (apps cannot send ICMP themselves): median of 3 replies.
Future<int?> icmpPing(String host) async {
  try {
    final r = Platform.isWindows
        ? await Process.run('ping', ['-n', '3', '-w', '2000', host])
        : await Process.run(Platform.isAndroid ? '/system/bin/ping' : 'ping', [
            '-c',
            '3',
            '-i',
            '0.3',
            '-W',
            '2',
            host,
          ]);
    final t = parsePingTimes('${r.stdout}');
    return t.isEmpty ? null : median(t);
  } catch (_) {
    return null; // no ping binary
  }
}

/// Times one HTTP request over a NEW connection through the core's local proxy (HTTP CONNECT with login):
/// connect + the tunnel to the site + the answer — what a page load waits for. [get] = GET instead of HEAD.
Future<int?> freshHttpPing(int proxyPort, String user, String password, {bool get = false}) async {
  const host = 'www.gstatic.com';
  final sw = Stopwatch()..start();
  Socket? s;
  try {
    s = await Socket.connect('127.0.0.1', proxyPort, timeout: const Duration(seconds: 5));
    final auth = base64.encode(utf8.encode('$user:$password'));
    s.write(
      'CONNECT $host:80 HTTP/1.1\r\nHost: $host:80\r\n'
      'Proxy-Authorization: Basic $auth\r\n\r\n'
      '${get ? 'GET' : 'HEAD'} /generate_204 HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
    );
    // the proxy's "200 Connection established", then the site's answer head
    final seen = StringBuffer();
    await for (final d in s.timeout(const Duration(seconds: 6))) {
      seen.write(String.fromCharCodes(d));
      final heads = RegExp(r'HTTP/1\.[01] (\d{3})').allMatches(seen.toString()).toList();
      if (heads.isNotEmpty && heads.first.group(1) != '200') return null; // the proxy refused
      if (heads.length >= 2) return sw.elapsedMilliseconds;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}
