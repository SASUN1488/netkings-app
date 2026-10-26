import 'dart:convert';

import 'subscription.dart';

/// Protocols the app subscription can carry (the profile label is the last part of an outbound tag,
/// e.g. "fi-relay3-grpc").
const protocols = {
  'auto': 'Авто (лучший)',
  'main': 'VLESS Reality',
  'grpc': 'VLESS gRPC',
  'hy2': 'Hysteria2',
};

/// DNS for sites abroad (asked through the tunnel, DoH).
const dnsServers = {
  'cloudflare': ('Cloudflare', '1.1.1.1'),
  'google': ('Google', '8.8.8.8'),
  'adguard': ('AdGuard — без рекламы', '94.140.14.14'),
};

/// Connection settings, kept in settings.json next to the subscription.
class Settings {
  String protocol = 'auto';
  String dns = 'cloudflare';
  bool directRu = true;       // .ru / .рф and Russian IPs bypass the VPN
  bool autoSwitch = true;     // the watchdog moves to another protocol / server when the current one dies
  bool autoConnect = false;   // connect as soon as the app starts

  Map<String, dynamic> toJson() =>
      {'protocol': protocol, 'dns': dns, 'directRu': directRu, 'autoSwitch': autoSwitch, 'autoConnect': autoConnect};

  static Settings fromJson(Map<String, dynamic> j) => Settings()
    ..protocol = protocols.containsKey(j['protocol']) ? j['protocol'] as String : 'auto'
    ..dns = dnsServers.containsKey(j['dns']) ? j['dns'] as String : 'cloudflare'
    ..directRu = j['directRu'] as bool? ?? true
    ..autoSwitch = j['autoSwitch'] as bool? ?? true
    ..autoConnect = j['autoConnect'] as bool? ?? false;

  static Future<Settings> load() async {
    try {
      final t = await Store.read('settings.json');
      return t == null ? Settings() : fromJson(jsonDecode(t) as Map<String, dynamic>);
    } on FormatException {
      return Settings();
    }
  }

  Future<void> save() => Store.write('settings.json', jsonEncode(toJson()));

  Settings copy() => fromJson(toJson());

  /// Changes that need the core restarted (autoConnect does not).
  bool sameCore(Settings o) => protocol == o.protocol && dns == o.dns && directRu == o.directRu;
}
