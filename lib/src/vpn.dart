import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_core.dart';

enum VpnState { stopped, starting, started, stopping }

/// The VPN: on Android NkVpnService with libbox inside (method / event channels), on Linux / Windows the
/// bundled sing-box process (DesktopCore).
class Vpn extends ChangeNotifier {
  static const _method = MethodChannel('netkings/vpn');
  static const _events = EventChannel('netkings/vpn/status');
  final DesktopCore? _desktop = Platform.isAndroid ? null : DesktopCore();

  VpnState state = VpnState.stopped;
  String? error;
  StreamSubscription? _sub;

  Vpn() {
    final Stream<dynamic> events = _desktop?.events ?? _events.receiveBroadcastStream();
    _sub = events.listen((e) {
      final m = Map<String, dynamic>.from(e as Map);
      state = VpnState.values.firstWhere((s) => s.name == m['status'], orElse: () => VpnState.stopped);
      error = m['error'] as String?;
      notifyListeners();
    });
  }

  /// false when the user declined the system VPN dialog (Android) / the admin password prompt (Linux).
  Future<bool> start(String config) async {
    error = null;
    final d = _desktop;
    if (d != null) return d.start(config);
    return await _method.invokeMethod<bool>('start', {'config': config}) ?? false;
  }

  Future<void> stop() async {
    final d = _desktop;
    if (d != null) return d.stop();
    await _method.invokeMethod('stop');
  }

  static Future<String?> initialLink() async =>
      Platform.isAndroid ? _method.invokeMethod<String>('initialLink') : null;

  /// Android "always-on VPN" / "block connections without VPN" page
  static Future<void> openSystemSettings() async {
    if (Platform.isAndroid) await _method.invokeMethod('vpnSettings');
  }

  static void onLink(void Function(String) handler) {
    if (!Platform.isAndroid) return;
    _method.setMethodCallHandler((call) async {
      if (call.method == 'link') handler(call.arguments as String);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _desktop?.stop();
    super.dispose();
  }
}
