import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/src/monitor.dart';

/// Fake clash API of the core: group "auto-pl" over two servers; `dead` stops answering delay tests,
/// a group re-test then moves "now" to a live server (as sing-box does once the dead one has no result).
class FakeCore {
  late HttpServer server;
  String now = 'pl-relay3-main';
  final dead = <String>{};
  bool homeUp = false;
  int dropNext = 0;
  final calls = <String>[];

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      final p = r.uri.path;
      calls.add(p);
      dynamic body;
      var code = 200;
      if (r.headers.value('authorization') != 'Bearer s') {
        code = 401;
      } else if (p == '/proxies/proxy') {
        body = {'now': 'auto-pl'};
      } else if (p == '/proxies/auto-pl') {
        body = {'now': now};
      } else if (p.endsWith('/delay') && p.startsWith('/proxies/')) {
        final tag = Uri.decodeComponent(p.split('/')[2]);
        if (dead.contains(tag) || dropNext-- > 0) {
          code = 504;
          body = {'message': 'An error occurred in the delay test'};
        } else {
          body = {'delay': 120};
        }
      } else if (p == '/group/auto-fi/delay') {
        body = homeUp ? {'fi-relay-main': 90} : {};
      } else if (p == '/group/auto-pl/delay') {
        if (dead.contains(now)) now = ['pl-relay-main', 'pl-relay-grpc'].firstWhere((t) => !dead.contains(t), orElse: () => now);
        body = {'pl-relay-main': 100};
      }
      r.response.statusCode = code;
      r.response.write(jsonEncode(body ?? {}));
      await r.response.close();
    });
  }
}

void main() {
  test('watchdog moves off a dead server and reports it', () async {
    final core = FakeCore();
    await core.start();
    final switched = <String>[];
    var deadCalls = 0;
    final m = Monitor('s', port: core.server.port, onSwitch: switched.add, onDead: () async => deadCalls++)
      ..retryDelay = Duration.zero
      ..attach();
    await m.tick();
    expect(m.ping, 120);
    expect(m.leaf, 'pl-relay3-main');

    core.dead.add('pl-relay3-main');
    await m.tick();                      // first failure (asked twice): just noted, last ping kept
    expect(m.ping, 120);
    expect(m.misses, 1);
    expect(core.calls.where((c) => c.startsWith('/group/')), isEmpty);
    await m.tick();                      // second: group re-test -> live server
    expect(core.calls.where((c) => c == '/group/auto-pl/delay').length, 1);
    expect(m.leaf, 'pl-relay-main');
    expect(m.ping, 120);
    expect(m.misses, 0);
    expect(switched, ['pl-relay-main']);
    expect(deadCalls, 0);

    // everything in the country dead: after two failed re-tests the app is told to widen the choice
    core.dead.addAll(['pl-relay-main', 'pl-relay-grpc']);
    for (var i = 0; i < 4; i++) {
      await m.tick();
    }
    expect(deadCalls, 1);
    expect(m.misses, greaterThanOrEqualTo(2));
    m.stop();
    await core.server.close(force: true);
  });

  test('one lost ping is asked again, not counted', () async {
    final core = FakeCore();
    await core.start();
    final m = Monitor('s', port: core.server.port)
      ..retryDelay = Duration.zero
      ..attach();
    core.dropNext = 1;                   // one dropped delay test
    await m.tick();
    expect(m.ping, 120);
    expect(m.misses, 0);
    m.stop();
    await core.server.close(force: true);
  });

  test('after a fallback the picked country is re-tested every minute and taken back', () async {
    final core = FakeCore();
    await core.start();
    var homeCalls = 0;
    final m = Monitor('s', port: core.server.port, home: 'auto-fi', onHome: () async => homeCalls++)
      ..retryDelay = Duration.zero
      ..attach();
    for (var i = 0; i < 6; i++) {
      await m.tick();
    }
    expect(core.calls.where((c) => c == '/group/auto-fi/delay').length, 1);
    expect(homeCalls, 0);                // still dead
    core.homeUp = true;
    for (var i = 0; i < 6; i++) {
      await m.tick();
    }
    expect(homeCalls, 1);
    m.stop();
    await core.server.close(force: true);
  });

  test('speed format', () {
    expect(formatSpeed(0), '0 бит/с');
    expect(formatSpeed(125000), '1.0 Мбит/с');
    expect(formatSpeed(5000000), '40 Мбит/с');
  });

  // against a real core: NK_SINGBOX=path/to/sing-box flutter test test/monitor_test.dart
  test('ping goes through the core\'s login proxy over a kept connection', () async {
    final bin = Platform.environment['NK_SINGBOX'];
    if (bin == null) return;
    final dir = await Directory.systemTemp.createTemp('nk');
    final cfg = File('${dir.path}/c.json')
      ..writeAsStringSync(jsonEncode({
        'log': {'level': 'info', 'output': '${dir.path}/log'},
        'inbounds': [
          {'type': 'mixed', 'tag': 'ping', 'listen': '127.0.0.1', 'listen_port': 29291,
            'users': [{'username': 'nk', 'password': 's3cret'}]},
        ],
        'outbounds': [{'type': 'direct', 'tag': 'proxy'}],
      }));
    final core = await Process.start(bin, ['run', '-c', cfg.path]);
    addTearDown(() async {
      core.kill();
      await dir.delete(recursive: true);
    });
    await Future.delayed(const Duration(seconds: 1));
    final good = Monitor('s3cret', proxyPort: 29291)..attach();
    for (var i = 0; i < 3; i++) {
      expect(await good.rtt(), isNotNull);
    }
    // all rounds over one kept tunnel
    final log = File('${dir.path}/log').readAsStringSync();
    expect(RegExp('inbound connection from').allMatches(log).length, 1);
    final wrong = Monitor('nope', proxyPort: 29291)..attach();
    expect(await wrong.rtt(), isNull);          // the proxy is not open to other apps on the device
  });
}
