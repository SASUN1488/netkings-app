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
        if (dead.contains(tag)) {
          code = 504;
          body = {'message': 'An error occurred in the delay test'};
        } else {
          body = {'delay': 120};
        }
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
    final m = Monitor('s', port: core.server.port, onSwitch: switched.add, onDead: () async => deadCalls++)..attach();
    await m.tick();
    expect(m.ping, 120);
    expect(m.leaf, 'pl-relay3-main');

    core.dead.add('pl-relay3-main');
    await m.tick();                      // first failure: just noted
    expect(m.ping, isNull);
    expect(core.calls.where((c) => c.startsWith('/group/')), isEmpty);
    await m.tick();                      // second: group re-test -> live server
    expect(core.calls.where((c) => c == '/group/auto-pl/delay').length, 1);
    expect(m.leaf, 'pl-relay-main');
    expect(m.ping, 120);
    expect(switched, ['pl-relay-main']);
    expect(deadCalls, 0);

    // everything in the country dead: after two failed re-tests the app is told to widen the choice
    core.dead.addAll(['pl-relay-main', 'pl-relay-grpc']);
    for (var i = 0; i < 4; i++) {
      await m.tick();
    }
    expect(deadCalls, 1);
    m.stop();
    await core.server.close(force: true);
  });

  test('speed format', () {
    expect(formatSpeed(0), '0 бит/с');
    expect(formatSpeed(125000), '1.0 Мбит/с');
    expect(formatSpeed(5000000), '40 Мбит/с');
  });
}
