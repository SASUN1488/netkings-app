import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/src/singbox.dart';
import 'package:netkings/src/subscription.dart';

void main() {
  test('builds a sing-box config from a real app subscription', () {
    final path = Platform.environment['NK_SUB'];
    if (path == null) return;
    final sub = Subscription('https://x/sub/y', jsonDecode(File(path).readAsStringSync()));
    for (final sel in ['auto', ...sub.countries.map((c) => c.tag)]) {
      final cfg = buildConfig(sub, sel, null, 'testsecret');
      File('${Platform.environment['NK_OUT']}/config-$sel.json').writeAsStringSync(cfg);
      final proxy = (jsonDecode(cfg)['outbounds'] as List).firstWhere((o) => o['tag'] == 'proxy');
      expect(proxy['default'], sel);
    }
    expect(parseSubscriptionLink('netkings://import/https%3A%2F%2F31.129.33.111%3A2096%2Fsub%2Fabc'),
        'https://31.129.33.111:2096/sub/abc');
  });
}
