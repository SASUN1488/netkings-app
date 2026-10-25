import 'dart:convert';

import 'subscription.dart';

/// Russian domains go direct (as on the servers): faster, and they pass the mobile operators' whitelists anyway.
const _directSuffixes = ['.ru', '.su', '.xn--p1ai'];

/// Full sing-box config for the core: the subscription's outbounds + a selector on the picked country,
/// TUN inbound (Android VpnService / desktop TUN), DNS over the tunnel.
String buildConfig(Subscription sub, String selected) {
  final groups = ['auto', ...sub.countries.map((c) => c.tag)];
  final config = {
    'log': {'level': 'warn', 'timestamp': true},
    'dns': {
      'servers': [
        {'type': 'https', 'tag': 'remote', 'server': '1.1.1.1', 'detour': 'proxy'},
        {'type': 'udp', 'tag': 'direct', 'server': '77.88.8.8'},
      ],
      'rules': [
        {'domain_suffix': _directSuffixes, 'server': 'direct'},
      ],
      'final': 'remote',
      'strategy': 'ipv4_only',
    },
    'inbounds': [
      {
        'type': 'tun',
        'tag': 'tun',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 1500,
        'auto_route': true,
        'strict_route': true,
        'stack': 'mixed',
      },
    ],
    'outbounds': [
      ...sub.outbounds,
      {'type': 'selector', 'tag': 'proxy', 'outbounds': groups, 'default': groups.contains(selected) ? selected : 'auto'},
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'rules': [
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true, 'outbound': 'direct'},
        {'domain_suffix': _directSuffixes, 'outbound': 'direct'},
      ],
      'final': 'proxy',
      'auto_detect_interface': true,
      'default_domain_resolver': 'direct',
    },
    'experimental': {
      'cache_file': {'enabled': true},
    },
  };
  return jsonEncode(config);
}
