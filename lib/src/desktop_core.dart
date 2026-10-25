import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Linux / Windows: the bundled sing-box binary runs as a child process with a TUN inbound.
/// Linux needs CAP_NET_ADMIN on that binary (granted once through pkexec + setcap); on Windows the app itself
/// runs elevated (runner manifest), which TUN (wintun) requires.
class DesktopCore {
  Process? _proc;
  final _status = StreamController<Map<String, String?>>.broadcast();
  String status = 'stopped';
  String? error;
  final _log = <String>[];

  Stream<Map<String, String?>> get events => _status.stream;

  void _set(String s, [String? e]) {
    status = s;
    if (s == 'starting') error = null;
    if (e != null) error = e;
    _status.add({'status': s, 'error': error});
  }

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  static String get coreBinary =>
      Platform.isWindows ? '$_exeDir\\core\\sing-box.exe' : '$_exeDir/lib/core/sing-box';

  /// Linux: TUN needs CAP_NET_ADMIN. Ask once (graphical password prompt), the capability stays on the file.
  static Future<String?> ensureLinuxCapability() async {
    final core = coreBinary;
    final have = await Process.run('getcap', [core]).then((r) => '${r.stdout}', onError: (_) => '');
    if (have.contains('cap_net_admin')) return null;
    final r = await Process.run('pkexec', ['setcap', 'cap_net_admin,cap_net_raw,cap_net_bind_service+ep', core]);
    if (r.exitCode != 0) {
      return 'Нужны права администратора, чтобы включить VPN (${'${r.stderr}'.trim().isEmpty ? 'отменено' : '${r.stderr}'.trim()})';
    }
    return null;
  }

  Future<bool> start(String config) async {
    if (_proc != null) return true;
    _set('starting');
    if (Platform.isLinux) {
      final err = await ensureLinuxCapability();
      if (err != null) {
        _set('stopped', err);
        return false;
      }
    }
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/core')..createSync(recursive: true);
    // "sing-box started" (our ready signal) is an info-level line
    final json = jsonDecode(config) as Map<String, dynamic>;
    (json['log'] as Map<String, dynamic>)['level'] = 'info';
    final cfg = File('${dir.path}/config.json')..writeAsStringSync(jsonEncode(json));
    _log.clear();
    try {
      final p = await Process.start(coreBinary, ['run', '-c', cfg.path, '-D', dir.path]);
      _proc = p;
      final started = Completer<bool>();
      void onLine(String line) {
        _log.add(line);
        if (_log.length > 50) _log.removeAt(0);
        if (line.contains('sing-box started') && !started.isCompleted) started.complete(true);
      }

      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      unawaited(p.exitCode.then((code) {
        _proc = null;
        if (!started.isCompleted) started.complete(false);
        final last = _log.where((l) => l.contains('FATAL') || l.contains('ERROR')).lastOrNull;
        _set('stopped', status == 'stopping' ? null : (last ?? 'ядро остановилось (код $code)'));
      }));
      final ok = await started.future.timeout(const Duration(seconds: 20), onTimeout: () => _proc != null);
      if (ok) _set('started');
      return ok;
    } on ProcessException catch (e) {
      _set('stopped', 'не удалось запустить ядро: ${e.message}');
      return false;
    }
  }

  Future<void> stop() async {
    final p = _proc;
    if (p == null) return;
    _set('stopping');
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}
