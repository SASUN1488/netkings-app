import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/src/ping.dart';
import 'package:netkings/src/singbox.dart';
import 'package:netkings/src/subscription.dart';

/// A local HTTP CONNECT proxy that answers [connect] and then the site's [site] line.
Future<ServerSocket> fakeProxy(String connect, String site) async {
  final ss = await ServerSocket.bind('127.0.0.1', 0);
  ss.listen((c) {
    var got = '';
    c.listen((d) {
      got += utf8.decode(d);
      if (got.contains('/generate_204')) {
        c.write('$connect\r\n\r\n');
        if (connect.contains(' 200 ')) c.write('$site\r\n\r\n');
      }
    }, onError: (_) {});
  });
  return ss;
}

void main() {
  test('system ping output: Linux, Android, Windows en / ru', () {
    expect(parsePingTimes('64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=12.6 ms\n... time=11.2 ms'), [13, 11]);
    expect(
      parsePingTimes('Reply from 1.1.1.1: bytes=32 time=14ms TTL=57\nReply from 1.1.1.1: bytes=32 time<1ms TTL=57'),
      [14, 1],
    );
    expect(parsePingTimes('Ответ от 1.1.1.1: число байт=32 время=15мс TTL=57'), [15]);
    expect(parsePingTimes('Request timed out.\n3 packets transmitted, 0 received'), isEmpty);
  });

  test('median ignores one slow sample; NK Ping parts', () {
    expect(median([40, 41, 900]), 41);
    expect(median([7]), 7);
    expect(const PingResult(90, 30).beyond, 60);
    expect(const PingResult(20, 30).beyond, 0); // a noisy entry sample never makes the VPN part negative
    expect(const PingResult(50).beyond, isNull);
  });

  test('tcp ping: an open port answers, a closed one does not', () async {
    final ss = await ServerSocket.bind('127.0.0.1', 0);
    ss.listen((c) => c.destroy());
    expect(await tcpPingMedian('127.0.0.1', ss.port), isNotNull);
    final port = ss.port;
    await ss.close();
    expect(await tcpPing('127.0.0.1', port, timeout: const Duration(milliseconds: 500)), isNull);
  });

  test('fresh HTTP ping through the proxy; a refused login is no answer', () async {
    final ok = await fakeProxy('HTTP/1.1 200 Connection established', 'HTTP/1.1 204 No Content');
    expect(await freshHttpPing(ok.port, 'nk', 's'), isNotNull);
    expect(await freshHttpPing(ok.port, 'nk', 's', get: true), isNotNull);
    final no = await fakeProxy('HTTP/1.1 407 Proxy Authentication Required', '');
    expect(await freshHttpPing(no.port, 'nk', 'wrong'), isNull);
    await ok.close();
    await no.close();
  });

  test('entry servers are left out of the TUN', () {
    final sub = Subscription('https://x/sub/y', {
      'active': true,
      'countries': [],
      'outbounds': [
        {'type': 'vless', 'tag': 'fi-relay-main', 'server': '31.129.33.111', 'server_port': 443},
        {'type': 'vless', 'tag': 'fi-relay3-main', 'server': '31.129.59.3', 'server_port': 443},
        {'type': 'vless', 'tag': 'fi-relay3-grpc', 'server': '31.129.59.3', 'server_port': 2083},
        {
          'type': 'urltest',
          'tag': 'auto',
          'outbounds': ['fi-relay-main'],
        },
      ],
    });
    final tun = (jsonDecode(buildConfig(sub, 'auto', null, 's'))['inbounds'] as List).first;
    expect(tun['route_exclude_address'], containsAll(['192.168.0.0/16', '31.129.33.111/32', '31.129.59.3/32']));
  });
}
