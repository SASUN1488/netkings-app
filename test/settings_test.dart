import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netkings/src/settings.dart';
import 'package:netkings/src/singbox.dart';
import 'package:netkings/src/subscription.dart';
import 'package:netkings/src/update.dart';

void main() {
  test('fixed protocol keeps only its servers in every group', () {
    final path = Platform.environment['NK_SUB'];
    if (path == null) return;
    final sub = Subscription('https://x/sub/y', jsonDecode(File(path).readAsStringSync()));
    for (final p in protocols.keys) {
      final cfg = jsonDecode(buildConfig(sub, 'auto', Settings()..protocol = p..directRu = p != 'hy2', 'sec'));
      for (final o in (cfg['outbounds'] as List).where((o) => o['type'] == 'urltest')) {
        expect(o['interrupt_exist_connections'], true);
        if (p != 'auto') expect((o['outbounds'] as List).every((t) => protocolOf(t) == p), true);
      }
      File('${Platform.environment['NK_OUT']}/config-$p.json').writeAsStringSync(jsonEncode(cfg));
    }
  });

  test('version compare', () {
    expect(newer('0.2.0', '0.1.0'), true);
    expect(newer('0.10.0', '0.9.9'), true);
    expect(newer('0.2.0', '0.2.0'), false);
    expect(newer('0.1.9', '0.2.0'), false);
  });
}
