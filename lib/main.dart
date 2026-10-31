import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/monitor.dart';
import 'src/settings.dart';
import 'src/singbox.dart';
import 'src/subscription.dart';
import 'src/update.dart';
import 'src/vpn.dart';

const _bg = Color(0xFF0B0A10);
const _surface = Color(0xFF15131D);
const _line = Color(0xFF272335);
const _purple = Color(0xFF9D6BFF);
const _green = Color(0xFF2EE59D);
const _muted = Color(0xFF8E8AA0);
const _red = Color(0xFFF0616D);
const _brand = LinearGradient(colors: [_green, _purple], begin: Alignment.topLeft, end: Alignment.bottomRight);
const _shopBot = 'https://t.me/NetKingsvpn_bot';

void main() => runApp(const NetKingsApp());

class NetKingsApp extends StatelessWidget {
  const NetKingsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NetKings VPN',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(primary: _purple, secondary: _green, surface: _surface, error: _red),
          switchTheme: SwitchThemeData(
            thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : _muted),
            trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _purple : _line),
          ),
          radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _green : _muted)),
          snackBarTheme: const SnackBarThemeData(backgroundColor: _surface, contentTextStyle: TextStyle(color: Colors.white)),
          fontFamily: 'Roboto',
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final vpn = Vpn();
  final _secret = List.generate(24, (_) => Random.secure().nextInt(36).toRadixString(36)).join();
  Subscription? sub;
  Settings settings = Settings();
  Monitor? monitor;
  Update? update;
  double? updateProgress;
  String country = 'auto';
  bool loading = true, refreshing = false;
  // the watchdog gave up on the picked protocol / country: "auto" until the user connects again
  bool _protoFallback = false, _countryFallback = false;
  String? message;
  DateTime? _lastFetch, _lastUpdateCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    vpn.addListener(_onVpn);
    Vpn.onLink(_importLink);
    _init();
  }

  Future<void> _init() async {
    country = await Store.read('country') ?? 'auto';
    settings = await Settings.load();
    sub = await cachedSubscription();
    final link = await Vpn.initialLink();
    setState(() => loading = false);
    unawaited(_checkUpdate());
    if (link != null) {
      await _importLink(link);
    } else if (sub != null) {
      unawaited(_refresh(silent: true));
      if (settings.autoConnect && vpn.state == VpnState.stopped) unawaited(_toggle());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) return;
    // the bot may have extended the subscription meanwhile; at most once per 10 min
    if (sub != null && (_lastFetch == null || DateTime.now().difference(_lastFetch!) > const Duration(minutes: 10))) {
      _refresh(silent: true);
    }
    if (_lastUpdateCheck == null || DateTime.now().difference(_lastUpdateCheck!) > const Duration(hours: 6)) {
      _checkUpdate();
    }
  }

  Future<void> _checkUpdate() async {
    _lastUpdateCheck = DateTime.now();
    final u = await checkUpdate();
    if (mounted) setState(() => update = u);
  }

  Future<void> _install() async {
    final u = update;
    if (u == null) return;
    if (!Platform.isAndroid) {
      _open(u.url);         // desktop: the browser downloads the new archive
      return;
    }
    setState(() => updateProgress = 0);
    try {
      await installAndroid(u, (p) => setState(() => updateProgress = p));
    } catch (e) {
      setState(() => message = 'Не удалось скачать обновление: $e');
    } finally {
      if (mounted) setState(() => updateProgress = null);
    }
  }

  void _onVpn() {
    if (vpn.error != null && vpn.state == VpnState.stopped) message = 'Не удалось подключиться: ${vpn.error}';
    if (vpn.state == VpnState.started && monitor == null) {
      monitor = Monitor(_secret,
          autoSwitch: settings.autoSwitch,
          onSwitch: _onSwitch,
          onDead: _onDead,
          home: _countryFallback ? country : null,
          onHome: _onHome)
        ..addListener(() => setState(() {}))
        ..start();
    } else if (vpn.state == VpnState.stopped && monitor != null) {
      monitor!.dispose();
      monitor = null;
    }
    setState(() {});
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(text)));

  void _onSwitch(String leaf) {
    if (mounted) _toast('Переключился: ${_leafLabel(leaf)}');
  }

  /// Nothing in the picked group answers even after a re-test: widen to every protocol, then every country.
  Future<void> _onDead() async {
    if (!settings.autoSwitch) return;
    if ((settings.protocol != 'auto') && !_protoFallback) {
      _protoFallback = true;
      _toast('${protocols[settings.protocol]} не отвечает — пробую все протоколы');
      await _restart();
    } else if (country != 'auto' && !_countryFallback) {
      _countryFallback = true;
      _toast('Серверы страны не отвечают — переключаюсь на самый быстрый');
      await _restart();
    }
  }

  /// The picked country answers again after a fallback to "auto": go back to it.
  Future<void> _onHome() async {
    if (!_countryFallback) return;
    _countryFallback = false;
    _toast('${_countryName(country)} снова работает — возвращаюсь');
    await _restart();
  }

  String _config() {
    final s = settings.copy();
    if (_protoFallback) s.protocol = 'auto';
    return buildConfig(sub!, _countryFallback ? 'auto' : country, s, _secret);
  }

  Future<void> _importLink(String text) async {
    final url = parseSubscriptionLink(text);
    if (url == null) {
      setState(() => message = 'Это не ссылка подписки NetKings');
      return;
    }
    await _load(url);
  }

  Future<void> _load(String url, {bool silent = false}) async {
    setState(() {
      refreshing = true;
      if (!silent) message = null;
    });
    try {
      final s = await fetchSubscription(url);
      _lastFetch = DateTime.now();
      final changed = sub != null && vpn.state == VpnState.started && s.raw.toString() != sub!.raw.toString();
      setState(() => sub = s);
      if (changed) await _restart();
    } catch (e) {
      if (!silent || sub == null) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (sub != null) await _load(sub!.url, silent: silent);
  }

  Future<void> _toggle() async {
    final s = sub;
    if (s == null) return;
    if (vpn.state == VpnState.started || vpn.state == VpnState.starting) {
      await vpn.stop();
      return;
    }
    if (!s.active || s.outbounds.isEmpty) {
      setState(() => message = s.notice ?? 'Подписка не активна');
      return;
    }
    _protoFallback = _countryFallback = false;
    setState(() => message = null);
    if (!await vpn.start(_config())) {
      setState(() => message = vpn.error ?? 'Нужно разрешить VPN-подключение');
    }
  }

  /// new country / new servers / new settings while connected: stop, wait for it, start again
  Future<void> _restart() async {
    if (vpn.state != VpnState.started) return;
    final stopped = Completer<void>();
    void l() {
      if (vpn.state == VpnState.stopped && !stopped.isCompleted) stopped.complete();
    }

    vpn.addListener(l);
    await vpn.stop();
    await stopped.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    vpn.removeListener(l);
    await vpn.start(_config());
  }

  Future<void> _pickCountry(String tag) async {
    if (tag == country && !_countryFallback) return;
    _countryFallback = false;
    setState(() => country = tag);
    await Store.write('country', tag);
    await _restart();
  }

  Future<void> _openSettings() async {
    final before = settings.copy();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(
        settings: settings,
        update: update,
        onCheckUpdate: () async {
          await _checkUpdate();
          return update;
        },
        onInstall: _install,
      ),
    ));
    await settings.save();
    if (!settings.sameCore(before)) {
      _protoFallback = false;
      await _restart();
    } else if (settings.autoSwitch != before.autoSwitch && monitor != null) {
      // the watchdog reads the flag at start: renew it
      monitor!.dispose();
      monitor = null;
      _onVpn();
    }
    setState(() {});
  }

  Future<void> _logout() async {
    await vpn.stop();
    await Store.delete('sub.json');
    await Store.delete('sub_url');
    setState(() => sub = null);
  }

  void _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    vpn.removeListener(_onVpn);
    monitor?.dispose();
    vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: SafeArea(
        child: sub == null
            ? _Welcome(onLink: _importLink, onBot: () => _open(_shopBot), busy: refreshing, message: message)
            : _main(sub!),
      ),
    );
  }

  Widget _main(Subscription s) {
    final st = vpn.state;
    final on = st == VpnState.started;
    final busy = st == VpnState.starting || st == VpnState.stopping;
    final statusText = switch (st) {
      VpnState.started => 'Подключено',
      VpnState.starting => 'Подключаю…',
      VpnState.stopping => 'Отключаю…',
      VpnState.stopped => 'Не подключено',
    };
    return RefreshIndicator(
      onRefresh: _refresh,
      color: _purple,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(children: [
            Image.asset('assets/icon/icon.png', width: 30, height: 30, filterQuality: FilterQuality.medium),
            const SizedBox(width: 10),
            const Text('NetKings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: .3)),
            const Spacer(),
            IconButton(
              tooltip: 'Обновить подписку',
              onPressed: refreshing ? null : _refresh,
              icon: refreshing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, color: _muted),
            ),
            IconButton(
              tooltip: 'Настройки',
              onPressed: _openSettings,
              icon: const Icon(Icons.tune_rounded, color: _muted),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: _muted),
              color: _surface,
              onSelected: (v) => v == 'logout' ? _logout() : null,
              itemBuilder: (_) => const [PopupMenuItem(value: 'logout', child: Text('Другая подписка'))],
            ),
          ]),
          if (update != null) ...[
            const SizedBox(height: 12),
            _UpdateCard(update: update!, progress: updateProgress, onInstall: _install),
          ],
          const SizedBox(height: 32),
          Center(child: _PowerButton(on: on, busy: busy, onTap: busy ? null : _toggle)),
          const SizedBox(height: 20),
          Center(
            child: Text(statusText,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: on ? _green : Colors.white)),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(on ? _onLabel(s) : 'Нажми, чтобы подключиться',
                textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 14)),
          ),
          const SizedBox(height: 16),
          _StatsBar(monitor: on ? monitor : null),
          const SizedBox(height: 24),
          const Text('СТРАНА', style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _CountryChip(label: '⚡ Авто', selected: country == 'auto', onTap: () => _pickCountry('auto')),
            for (final c in s.countries)
              _CountryChip(label: _flag(c) + c.name, selected: country == c.tag, onTap: () => _pickCountry(c.tag)),
          ]),
          const SizedBox(height: 24),
          _SubscriptionCard(sub: s, onBot: () => _open(s.bot.isNotEmpty ? s.bot : _shopBot)),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, style: const TextStyle(color: _red, fontSize: 14)),
          ],
        ],
      ),
    );
  }

  /// Windows fonts have no flag emoji (they come out as "FI"): names only there
  static String _flag(Country c) => Platform.isWindows || c.flag.isEmpty ? '' : '${c.flag} ';

  String _countryName(String tag) {
    final c = sub?.countries.where((c) => c.tag == tag) ?? const <Country>[];
    return c.isEmpty ? 'Выбранная страна' : _flag(c.first) + c.first.name;
  }

  /// "fi-relay3-grpc" -> "🇫🇮 Финляндия · VLESS gRPC · вход 2"
  String _leafLabel(String leaf) {
    final s = sub;
    final parts = leaf.split('-');
    if (s == null || parts.length < 3) return leaf;
    final c = s.countries.where((c) => c.id == parts.first);
    final entries = <String>[];
    for (final o in s.outbounds) {
      final p = '${o['tag']}'.split('-');
      if (p.length >= 3 && o['type'] != 'urltest') {
        final e = p.sublist(1, p.length - 1).join('-');
        if (!entries.contains(e)) entries.add(e);
      }
    }
    final entry = parts.sublist(1, parts.length - 1).join('-');
    final proto = protocols[protocolOf(leaf)] ?? protocolOf(leaf);
    return [
      if (c.isNotEmpty) _flag(c.first) + c.first.name,
      proto,
      if (entries.length > 1) 'вход ${entries.indexOf(entry) + 1}',
    ].join(' · ');
  }

  String _onLabel(Subscription s) {
    final leaf = monitor?.leaf;
    if (leaf != null && leaf.split('-').length >= 3) return _leafLabel(leaf);
    if (country == 'auto' || _countryFallback) return 'Самый быстрый сервер';
    final c = s.countries.where((c) => c.tag == country);
    return c.isEmpty ? 'Самый быстрый сервер' : _flag(c.first) + c.first.name;
  }
}

class _StatsBar extends StatelessWidget {
  final Monitor? monitor;
  const _StatsBar({this.monitor});

  @override
  Widget build(BuildContext context) {
    final m = monitor;
    Widget cell(IconData icon, String label, String value, Color color) => Expanded(
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
            ]),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: m == null ? _muted : Colors.white)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
      child: Row(children: [
        cell(Icons.south_rounded, 'Загрузка', m == null ? '—' : formatSpeed(m.down), _green),
        Container(width: 1, height: 32, color: _line),
        cell(Icons.north_rounded, 'Отдача', m == null ? '—' : formatSpeed(m.up), _purple),
        Container(width: 1, height: 32, color: _line),
        cell(Icons.network_ping_rounded, 'Пинг', _pingText(m), _pingColor(m)),
      ]),
    );
  }
}

/// "…" only while the first answer is awaited; one missed round keeps the last value (greyed),
/// two in a row are a real "нет ответа".
String _pingText(Monitor? m) {
  if (m == null) return '—';
  if (m.misses >= 2) return 'нет ответа';
  return m.ping == null ? '…' : '${m.ping} мс';
}

Color _pingColor(Monitor? m) {
  final ping = m?.ping;
  if (m == null || ping == null) return _muted;
  if (m.misses >= 2) return _red;
  if (m.misses == 1) return _muted;
  return ping < 400 ? _green : (ping < 1000 ? _purple : _red);
}

class _UpdateCard extends StatelessWidget {
  final Update update;
  final double? progress;
  final VoidCallback onInstall;
  const _UpdateCard({required this.update, required this.progress, required this.onInstall});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _purple.withValues(alpha: .6)),
          color: _purple.withValues(alpha: .10),
        ),
        child: Row(children: [
          const Icon(Icons.system_update_rounded, color: _green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Доступна версия ${update.version}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              progress == null
                  ? Text('У тебя $appVersion', style: const TextStyle(color: _muted, fontSize: 13))
                  : Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: LinearProgressIndicator(value: progress, color: _green, backgroundColor: _line),
                    ),
            ]),
          ),
          FilledButton(
            onPressed: progress == null ? onInstall : null,
            style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: Colors.white),
            child: const Text('Обновить'),
          ),
        ]),
      );
}

class _PowerButton extends StatelessWidget {
  final bool on, busy;
  final VoidCallback? onTap;
  const _PowerButton({required this.on, required this.busy, this.onTap});

  @override
  Widget build(BuildContext context) {
    final glow = on ? _green : _purple;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 184,
        height: 184,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: on ? _brand : null,
          color: on ? null : _purple.withValues(alpha: .55),
          boxShadow: [BoxShadow(color: glow.withValues(alpha: on ? .35 : .14), blurRadius: on ? 48 : 24, spreadRadius: 2)],
        ),
        child: Container(
          decoration: const BoxDecoration(shape: BoxShape.circle, color: _surface),
          child: Stack(alignment: Alignment.center, children: [
            if (busy) SizedBox(width: 170, height: 170, child: CircularProgressIndicator(strokeWidth: 3, color: glow)),
            on
                ? ShaderMask(
                    shaderCallback: (r) => _brand.createShader(r),
                    child: const Icon(Icons.power_settings_new_rounded, size: 76, color: Colors.white),
                  )
                : const Icon(Icons.power_settings_new_rounded, size: 76, color: _purple),
          ]),
        ),
      ),
    );
  }
}

class _CountryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CountryChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _purple.withValues(alpha: .16) : _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _purple : _line),
          ),
          child: Text(label, style: TextStyle(fontSize: 15, color: selected ? Colors.white : Colors.white70)),
        ),
      );
}

class _SubscriptionCard extends StatelessWidget {
  final Subscription sub;
  final VoidCallback onBot;
  const _SubscriptionCard({required this.sub, required this.onBot});

  @override
  Widget build(BuildContext context) {
    final exp = sub.expires;
    final left = exp?.difference(DateTime.now());
    final String line;
    Color color = Colors.white;
    if (sub.notice != null) {
      line = sub.notice!;
      color = _red;
    } else if (exp == null) {
      line = 'Подписка активна';
    } else if (left!.isNegative) {
      line = 'Подписка закончилась';
      color = _red;
    } else {
      line = 'Подписка до ${_d(exp)}';
      if (left.inDays < 3) color = _purple;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(line, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color)),
        if (left != null && !left.isNegative && sub.notice == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Осталось ${_left(left)}', style: const TextStyle(color: _muted, fontSize: 13)),
          ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: onBot,
              style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(44)),
              child: const Text('Продлить', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              onPressed: onBot,
              style: OutlinedButton.styleFrom(side: const BorderSide(color: _line), minimumSize: const Size.fromHeight(44)),
              child: const Text('Поддержка', style: TextStyle(color: Colors.white)),
            ),
          ),
        ]),
      ]),
    );
  }

  static String _d(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';

  static String _left(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} ${_plural(d.inDays, 'день', 'дня', 'дней')}';
    return '${d.inHours} ${_plural(d.inHours, 'час', 'часа', 'часов')}';
  }

  static String _plural(int n, String one, String few, String many) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }
}

/// Connection settings (changes are saved and applied when the page closes).
class SettingsPage extends StatefulWidget {
  final Settings settings;
  final Update? update;
  final Future<Update?> Function() onCheckUpdate;
  final VoidCallback onInstall;
  const SettingsPage({super.key, required this.settings, required this.update, required this.onCheckUpdate, required this.onInstall});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings get s => widget.settings;
  Update? update;
  bool checking = false;
  String? checked;

  @override
  void initState() {
    super.initState();
    update = widget.update;
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Text(title, style: const TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
      );

  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
        child: Column(children: children),
      );

  Widget _radio<T>(String title, T value, T group, ValueChanged<T> onChanged, {String? subtitle}) => ListTile(
        onTap: () => setState(() => onChanged(value)),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12)),
        trailing: Icon(value == group ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
            color: value == group ? _green : _muted),
      );

  Widget _switch(String title, String subtitle, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        value: value,
        onChanged: (v) => setState(() => onChanged(v)),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12)),
      );

  static const _protoHints = {
    'auto': 'Сам выбирает самый быстрый из работающих',
    'main': 'Основной, маскируется под обычный сайт',
    'grpc': 'Запасной, если основной режут',
    'hy2': 'UDP (QUIC): быстрый, но на части мобильных сетей не работает',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: _bg, title: const Text('Настройки')),
        body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          _section('ПРОТОКОЛ'),
          _card([
            for (final e in protocols.entries)
              _radio(e.value, e.key, s.protocol, (v) => s.protocol = v, subtitle: _protoHints[e.key]),
          ]),
          _section('ПОДКЛЮЧЕНИЕ'),
          _card([
            _switch('Автопереключение', 'Если сервер или протокол перестал отвечать — сразу перейти на рабочий',
                s.autoSwitch, (v) => s.autoSwitch = v),
            _switch('Российские сайты напрямую', 'Госуслуги, банки и .ru открываются без VPN — быстрее и без блокировок',
                s.directRu, (v) => s.directRu = v),
            _switch('Подключаться при запуске', 'VPN включается сам, как только открываешь приложение',
                s.autoConnect, (v) => s.autoConnect = v),
            if (Platform.isAndroid)
              ListTile(
                onTap: Vpn.openSystemSettings,
                title: const Text('Постоянный VPN и блокировка без VPN'),
                subtitle: const Text('Системные настройки Android: «Постоянная VPN» и «Блокировать соединения без VPN»',
                    style: TextStyle(color: _muted, fontSize: 12)),
                trailing: const Icon(Icons.open_in_new_rounded, color: _muted, size: 20),
              ),
          ]),
          _section('DNS'),
          _card([
            for (final e in dnsServers.entries) _radio(e.value.$1, e.key, s.dns, (v) => s.dns = v),
          ]),
          _section('ПРИЛОЖЕНИЕ'),
          _card([
            ListTile(
              title: Text('NetKings $appVersion'),
              subtitle: Text(
                  update != null ? 'Доступна версия ${update!.version}' : (checked ?? 'Обновления проверяются сами'),
                  style: TextStyle(color: update != null ? _green : _muted, fontSize: 12)),
              trailing: update != null
                  ? FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onInstall();
                      },
                      style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: Colors.white),
                      child: const Text('Обновить'))
                  : TextButton(
                      onPressed: checking
                          ? null
                          : () async {
                              setState(() => checking = true);
                              final u = await widget.onCheckUpdate();
                              if (mounted) {
                                setState(() {
                                  checking = false;
                                  update = u;
                                  checked = u == null ? 'Последняя версия' : null;
                                });
                              }
                            },
                      child: checking
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Проверить', style: TextStyle(color: _purple))),
            ),
          ]),
        ]),
      );
}

class _Welcome extends StatefulWidget {
  final Future<void> Function(String) onLink;
  final VoidCallback onBot;
  final bool busy;
  final String? message;
  const _Welcome({required this.onLink, required this.onBot, required this.busy, this.message});

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  final ctl = TextEditingController();

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
        children: [
          ShaderMask(
            shaderCallback: (r) => _brand.createShader(r),
            child: const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 64),
          ),
          const SizedBox(height: 12),
          const Text('NetKings VPN',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('Работает там, где другие не работают',
              textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 15)),
          const SizedBox(height: 40),
          FilledButton.icon(
            onPressed: widget.onBot,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Получить доступ в боте', style: TextStyle(fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 10),
          const Text('Пробный период 3 дня — бесплатно. В боте нажми «📲 Открыть в NetKings».',
              textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 13)),
          const SizedBox(height: 32),
          const Text('УЖЕ ЕСТЬ ССЫЛКА?', style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 10),
          TextField(
            controller: ctl,
            decoration: InputDecoration(
              hintText: 'https://…/sub/…',
              filled: true,
              fillColor: _surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _line)),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: widget.busy ? null : () => widget.onLink(ctl.text),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: _line), minimumSize: const Size.fromHeight(48)),
            child: widget.busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Добавить', style: TextStyle(color: Colors.white)),
          ),
          if (widget.message != null) ...[
            const SizedBox(height: 14),
            Text(widget.message!, textAlign: TextAlign.center, style: const TextStyle(color: _red)),
          ],
        ],
      );
}
