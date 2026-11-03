import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/monitor.dart';
import 'src/secrets.dart';
import 'src/settings.dart';
import 'src/singbox.dart';
import 'src/subscription.dart';
import 'src/update.dart';
import 'src/vpn.dart';

// colours come from the palette: an easter-egg look can take them from its picture (src/secrets.dart)
Color get _bg => palette.bg;
Color get _surface => palette.surface;
Color get _line => palette.line;
Color get _purple => palette.accent;
Color get _green => palette.accent2;
Color get _muted => palette.muted;
const _red = Color(0xFFF0616D);
LinearGradient get _brand =>
    LinearGradient(colors: [_green, _purple], begin: Alignment.topLeft, end: Alignment.bottomRight);
const _shopBot = 'https://t.me/NetKingsvpn_bot';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadEggs();
  runApp(const NetKingsApp());
}

class NetKingsApp extends StatelessWidget {
  const NetKingsApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Look?>(
    valueListenable: look,
    builder: (context, on, _) => MaterialApp(
      title: 'NetKings VPN',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final w = wallpaper;
        return w == null
            ? child!
            : Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: _bg, child: w),
                  child!,
                ],
              );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: on != null ? Colors.transparent : _bg,
        colorScheme: ColorScheme.dark(primary: _purple, secondary: _green, surface: _surface, error: _red),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : _muted),
          trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _purple : _line),
        ),
        radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _green : _muted),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: _surface,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const Home(),
    ),
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
  bool autoPick = true; // "Автовыбор": the core picks the best of all servers; off = [server] by hand
  String? server; // e.g. "fi-relay3-grpc"
  Map<String, int?> pings = {}; // server list: last delay test, null = no answer
  bool testing = false;
  bool collapsed = false; // home: the server list folded to one row (the server in use)
  int tab = 0; // bottom bar: 0 home, 1 servers, 2 settings
  Settings? _settingsBefore; // settings as they were when the settings tab was opened
  bool loading = true, refreshing = false;
  // the watchdog gave up on the picked protocol / country / server: a wider pick until the user connects again
  bool _protoFallback = false, _countryFallback = false;
  String? message;
  DateTime? _lastFetch, _lastUpdateCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    vpn.addListener(_onVpn);
    look.addListener(_onEgg);
    Vpn.onLink(_importLink);
    _init();
  }

  Future<void> _init() async {
    autoPick = await Store.read('auto_pick') != '0';
    collapsed = await Store.read('servers_collapsed') == '1';
    server = await Store.read('server');
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
      _open(u.url); // desktop: the browser downloads the new archive
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
      monitor =
          Monitor(
              _secret,
              autoSwitch: settings.autoSwitch,
              onSwitch: _onSwitch,
              onDead: _onDead,
              home: _countryFallback ? _pick : null,
              onHome: _onHome,
            )
            ..addListener(() => setState(() {}))
            ..start();
      // the core's API is up ~2 s after start: then the list shows real pings through each server
      Future.delayed(const Duration(seconds: 4), () => monitor != null ? _testPings() : null);
    } else if (vpn.state == VpnState.stopped && monitor != null) {
      monitor!.dispose();
      monitor = null;
      pings = {}; // numbers from the tunnel are meaningless without it: "—" until the next connect
    }
    setState(() {});
  }

  void _onEgg() => setState(() {});

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _onSwitch(String leaf) {
    if (mounted) _toast('Переключился: ${_leafLabel(leaf)}');
  }

  List<String> get _leaves => sub == null ? const [] : leafTags(sub!);

  /// A server picked by hand that the subscription still has.
  bool get _manual => !autoPick && server != null && _leaves.contains(server);

  /// What the core is told to use: the hand-picked server, else "auto" (the best of all servers).
  String get _pick => _manual ? server! : 'auto';

  /// Where a fallback goes: a dead hand-picked server -> the best one of its country; a dead country -> "auto".
  String get _fallbackTo {
    if (!_manual) return 'auto';
    final c = sub!.countries.where((c) => c.id == server!.split('-').first);
    return c.isEmpty ? 'auto' : c.first.tag;
  }

  /// Nothing in the picked group answers even after a re-test: widen to every protocol, then every country
  /// (a hand-picked server: to its country).
  Future<void> _onDead() async {
    if (!settings.autoSwitch) return;
    if (!_manual && settings.protocol != 'auto' && !_protoFallback) {
      _protoFallback = true;
      _toast('${protocols[settings.protocol]} не отвечает — пробую все протоколы');
      await _restart();
    } else if (_pick != 'auto' && !_countryFallback) {
      _countryFallback = true;
      _toast(
        _manual
            ? 'Сервер не отвечает — временно переключаюсь на рабочий'
            : 'Серверы страны не отвечают — переключаюсь на самый быстрый',
      );
      await _restart();
    }
  }

  /// The user's pick answers again after a fallback: go back to it.
  Future<void> _onHome() async {
    if (!_countryFallback) return;
    _countryFallback = false;
    _toast('${_manual ? _leafLabel(server!) : 'Выбранный сервер'} снова работает — возвращаюсь');
    await _restart();
  }

  String _config() {
    final s = settings.copy();
    if (_protoFallback) s.protocol = 'auto';
    return buildConfig(sub!, _countryFallback ? _fallbackTo : _pick, s, _secret);
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

  /// A tap in the server list: that server only (Автовыбор goes off).
  Future<void> _pickServer(String tag) async {
    if (tag == server && _manual && !_countryFallback) return;
    final wasAuto = autoPick;
    _countryFallback = false;
    setState(() {
      server = tag;
      autoPick = false;
    });
    await Store.write('server', tag);
    await Store.write('auto_pick', '0');
    if (wasAuto) _toast('Автовыбор выключен — подключаюсь только к этому серверу');
    await _restart();
  }

  /// "Автовыбор" off: start from the server in use, so nothing changes until the user picks another one.
  Future<void> _setAutoPick(bool v) async {
    final before = _pick;
    final leaf = monitor?.leaf;
    setState(() {
      autoPick = v;
      if (!v && !_leaves.contains(server) && leaf != null && _leaves.contains(leaf)) server = leaf;
    });
    await Store.write('auto_pick', v ? '1' : '0');
    if (server != null) await Store.write('server', server!);
    if (_pick != before || _countryFallback) {
      _countryFallback = false;
      await _restart();
    }
    if (!v && monitor != null && pings.isEmpty) unawaited(_testPings());
  }

  /// Connected: a real request through every server (the core's delay test). Not connected: TCP connect
  /// time to each entry (shows only that the entry is reachable).
  /// Only while connected: a real request through every server (the core's delay test). Without the core
  /// a direct check would measure only the way to the entry — or to another VPN app's tunnel (fake "6 ms").
  Future<void> _testPings() async {
    final m = monitor;
    if (testing || m == null) return;
    setState(() => testing = true);
    final r = await m.testServers(_leaves);
    if (mounted) {
      setState(() {
        if (monitor == m) pings = r; // disconnected meanwhile: keep "—"
        testing = false;
      });
    }
  }

  Future<void> _goTab(int i) async {
    if (i == tab) return;
    final leaving = tab;
    setState(() => tab = i);
    if (i == 2) _settingsBefore = settings.copy();
    if (leaving == 2) await _applySettings();
    if (i == 1 && pings.isEmpty) unawaited(_testPings());
  }

  /// Leaving the settings tab: save, restart the core / watchdog if what they use changed.
  Future<void> _applySettings() async {
    final before = _settingsBefore ?? settings.copy();
    _settingsBefore = null;
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
    look.removeListener(_onEgg);
    monitor?.dispose();
    vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return Scaffold(body: Center(child: CircularProgressIndicator()));
    final s = sub;
    if (s == null) {
      return Scaffold(
        body: SafeArea(
          child: _Welcome(onLink: _importLink, onBot: () => _open(_shopBot), busy: refreshing, message: message),
        ),
      );
    }
    return PopScope(
      canPop: tab == 0, // Android back: to the home tab first
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTab(0);
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: AnimatedSwitcher(
            duration: Duration(milliseconds: 250),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: Offset(0, .03), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(tab),
              child: switch (tab) {
                1 => _serversTab(s),
                2 => SettingsPage(
                  settings: settings,
                  embedded: true,
                  update: update,
                  onCheckUpdate: () async {
                    await _checkUpdate();
                    return update;
                  },
                  onInstall: () {
                    _goTab(0);
                    _install();
                  },
                ),
                _ => _main(s),
              },
            ),
          ),
        ),
        bottomNavigationBar: _NavBar(index: tab, onTap: _goTab),
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
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(
            children: [
              Image.asset('assets/icon/icon.png', width: 30, height: 30, filterQuality: FilterQuality.medium),
              SizedBox(width: 10),
              Text('NetKings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: .3)),
              Spacer(),
              IconButton(
                tooltip: 'Обновить подписку',
                onPressed: refreshing ? null : _refresh,
                icon: refreshing
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.refresh_rounded, color: _muted),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: _muted),
                color: _surface,
                onSelected: (v) => v == 'logout' ? _logout() : null,
                itemBuilder: (_) => [PopupMenuItem(value: 'logout', child: Text('Другая подписка'))],
              ),
            ],
          ),
          if (update != null) ...[
            SizedBox(height: 12),
            _UpdateCard(update: update!, progress: updateProgress, onInstall: _install),
          ],
          SizedBox(height: 32),
          Center(
            child: _PowerButton(on: on, busy: busy, onTap: busy ? null : _toggle),
          ),
          SizedBox(height: 20),
          Center(
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: 300),
              child: Text(
                statusText,
                key: ValueKey(statusText),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: on ? _green : Colors.white),
              ),
            ),
          ),
          SizedBox(height: 6),
          Center(
            child: Text(
              on ? _onLabel(s) : 'Нажми, чтобы подключиться',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: 14),
            ),
          ),
          SizedBox(height: 16),
          _StatsBar(monitor: on ? monitor : null),
          SizedBox(height: 24),
          Row(
            children: [
              InkWell(
                onTap: _toggleCollapsed,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Text('СЕРВЕРЫ', style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
                      Icon(collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded, color: _muted, size: 20),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Проверить пинг',
                visualDensity: VisualDensity.compact,
                onPressed: testing || monitor == null ? null : _testPings,
                icon: testing
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.speed_rounded, color: _muted, size: 20),
              ),
              Spacer(),
              Text('Автовыбор', style: TextStyle(fontSize: 14)),
              SizedBox(width: 4),
              Switch(value: autoPick, onChanged: _setAutoPick),
            ],
          ),
          SizedBox(height: 4),
          AnimatedSize(
            duration: Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: Column(children: collapsed ? [_currentRow()] : _serverRows()),
          ),
          SizedBox(height: 24),
          _SubscriptionCard(sub: s, onBot: () => _open(s.bot.isNotEmpty ? s.bot : _shopBot)),
          if (message != null) ...[SizedBox(height: 16), Text(message!, style: TextStyle(color: _red, fontSize: 14))],
        ],
      ),
    );
  }

  Map<String, Map> get _outboundsByTag => {for (final o in sub?.outbounds ?? []) '${o['tag']}': o as Map};

  /// Like Incy: one flat list of every server — flag, name, protocol line, ping. A tap = that server only.
  Widget _serversTab(Subscription s) {
    return RefreshIndicator(
      onRefresh: _testPings,
      color: _purple,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          Row(
            children: [
              Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text('Серверы', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              ),
              Spacer(),
              IconButton(
                tooltip: 'Проверить пинг',
                onPressed: testing || monitor == null ? null : _testPings,
                icon: testing
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.speed_rounded, color: _muted),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              autoPick
                  ? 'Сейчас включён автовыбор. Нажми на сервер — буду подключаться только к нему.'
                  : 'Подключаюсь только к выбранному серверу. Вернуть автовыбор — переключатель на главной.',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
          ),
          ..._serverRows(),
        ],
      ),
    );
  }

  Future<void> _toggleCollapsed() async {
    setState(() => collapsed = !collapsed);
    await Store.write('servers_collapsed', collapsed ? '1' : '0');
  }

  /// Folded list: the server in use (connected) or the picked one, with its ping; a tap unfolds the list.
  Widget _currentRow() {
    final m = monitor;
    final live = m?.leaf != null && _leaves.contains(m!.leaf) ? m.leaf : null;
    final l = live ?? (_manual ? server : null);
    if (l == null) {
      return _ServerRow(
        flag: '⚡',
        title: 'Автовыбор',
        parts: [],
        subtitle: 'Лучший из ${_leaves.length} серверов',
        selected: false,
        inUse: false,
        tested: false,
        onTap: _toggleCollapsed,
      );
    }
    // connected: the live ping of the header (one round trip), else the list's last test
    final ping = live != null && m!.ping != null && m.misses < 2 ? m.ping : pings[l];
    final tested = live != null ? (m!.ping != null || pings.containsKey(l)) : pings.containsKey(l);
    return _ServerRow(
      flag: _flagOf(l),
      title: _leafName(l),
      parts: _protoParts(_outboundsByTag[l]),
      selected: _manual && server == l,
      inUse: live != null,
      tested: tested,
      ping: ping,
      onTap: _toggleCollapsed,
    );
  }

  /// Every server, Incy style. Автовыбор on: the one the core uses has a green dot; a tap = that server only.
  List<Widget> _serverRows() {
    final on = monitor != null;
    final obs = _outboundsByTag;
    return [
      for (final l in _leaves)
        _ServerRow(
          flag: _flagOf(l),
          title: _leafName(l),
          parts: _protoParts(obs[l]),
          selected: _manual && server == l,
          inUse: on && monitor!.leaf == l,
          tested: pings.containsKey(l),
          ping: pings[l],
          onTap: () => _pickServer(l),
        ),
    ];
  }

  /// The entries (RU relays) in subscription order: the 2nd one's servers are named "2 main" etc., as in Incy.
  List<String> get _entries {
    final entries = <String>[];
    for (final l in _leaves) {
      final p = l.split('-');
      if (p.length < 3) continue;
      final e = p.sublist(1, p.length - 1).join('-');
      if (!entries.contains(e)) entries.add(e);
    }
    return entries;
  }

  /// "fi-relay3-grpc" -> "2 grpc"
  String _leafName(String leaf) {
    final p = leaf.split('-');
    if (p.length < 3) return leaf;
    final i = _entries.indexOf(p.sublist(1, p.length - 1).join('-'));
    return '${i > 0 ? '${i + 1} ' : ''}${p.last}';
  }

  /// Flag emoji of the server's country; Windows has no flag glyphs: the country code.
  String _flagOf(String leaf) {
    final id = leaf.split('-').first;
    final c = sub?.countries.where((c) => c.id == id) ?? <Country>[];
    return Platform.isWindows || c.isEmpty || c.first.flag.isEmpty ? id.toUpperCase() : c.first.flag;
  }

  /// "VLESS · TCP · REALITY" from the outbound itself.
  static List<String> _protoParts(Map? o) {
    if (o == null) return [];
    final type = '${o['type']}';
    final tr = (o['transport'] as Map?)?['type'] as String? ?? (type == 'hysteria2' ? 'quic' : 'tcp');
    final tls = o['tls'] as Map?;
    final sec = (tls?['reality'] as Map?)?['enabled'] == true ? 'REALITY' : (tls?['enabled'] == true ? 'TLS' : '');
    const names = {
      'tcp': 'TCP',
      'grpc': 'gRPC',
      'quic': 'QUIC',
      'http': 'XHTTP',
      'ws': 'WS',
      'httpupgrade': 'HTTPUpgrade',
    };
    return [type.toUpperCase(), names[tr] ?? tr.toUpperCase(), if (sec.isNotEmpty) sec];
  }

  /// Windows fonts have no flag emoji (they come out as "FI"): names only there
  static String _flag(Country c) => Platform.isWindows || c.flag.isEmpty ? '' : '${c.flag} ';

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
    final proto = protocols[protocolOf(leaf)] ?? _protoNames[protocolOf(leaf)] ?? protocolOf(leaf);
    return [
      if (c.isNotEmpty) _flag(c.first) + c.first.name,
      proto,
      if (entries.length > 1) 'вход ${entries.indexOf(entry) + 1}',
    ].join(' · ');
  }

  /// Profiles that are not a choice in the settings (protocols) but do come in the subscription.
  static const _protoNames = {'lte': 'VLESS LTE', 'reserve': 'VLESS XHTTP'};

  String _onLabel(Subscription s) {
    final leaf = monitor?.leaf;
    if (leaf != null && leaf.split('-').length >= 3) return _leafLabel(leaf);
    return _manual && !_countryFallback ? _leafLabel(server!) : 'Самый быстрый сервер';
  }
}

class _StatsBar extends StatelessWidget {
  final Monitor? monitor;
  const _StatsBar({this.monitor});

  @override
  Widget build(BuildContext context) {
    final m = monitor;
    Widget cell(IconData icon, String label, String value, Color color) => Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              SizedBox(width: 4),
              Text(label, style: TextStyle(color: _muted, fontSize: 12)),
            ],
          ),
          SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: m == null ? _muted : Colors.white),
          ),
        ],
      ),
    );
    return Container(
      padding: EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: _surface,
        image: panelImage,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          cell(Icons.south_rounded, 'Загрузка', m == null ? '—' : formatSpeed(m.down), _green),
          Container(width: 1, height: 32, color: _line),
          cell(Icons.north_rounded, 'Отдача', m == null ? '—' : formatSpeed(m.up), _purple),
          Container(width: 1, height: 32, color: _line),
          cell(Icons.network_ping_rounded, 'Пинг', _pingText(m), _pingColor(m)),
        ],
      ),
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
    padding: EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _purple.withValues(alpha: .6)),
      color: _purple.withValues(alpha: .10),
    ),
    child: Row(
      children: [
        Icon(Icons.system_update_rounded, color: _green),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Доступна версия ${update.version}', style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              progress == null
                  ? Text('У тебя $appVersion', style: TextStyle(color: _muted, fontSize: 13))
                  : Padding(
                      padding: EdgeInsets.only(top: 6, right: 8),
                      child: LinearProgressIndicator(value: progress, color: _green, backgroundColor: _line),
                    ),
            ],
          ),
        ),
        FilledButton(
          onPressed: progress == null ? onInstall : null,
          style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: palette.onAccent),
          child: Text('Обновить'),
        ),
      ],
    ),
  );
}

class _PowerButton extends StatefulWidget {
  final bool on, busy;
  final VoidCallback? onTap;
  const _PowerButton({required this.on, required this.busy, this.onTap});

  @override
  State<_PowerButton> createState() => _PowerButtonState();
}

/// Connected: the glow slowly breathes. Connecting: it pulses faster. A press shrinks the button a little.
class _PowerButtonState extends State<_PowerButton> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: Duration(milliseconds: 2400));
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_PowerButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final d = Duration(milliseconds: widget.busy ? 900 : 2400);
    if (widget.on || widget.busy) {
      if (_pulse.duration != d || !_pulse.isAnimating) {
        _pulse.duration = d;
        _pulse.repeat(reverse: true);
      }
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse.stop();
      _pulse.animateTo(0, duration: Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.on, busy = widget.busy;
    final glow = on ? _green : _purple;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? .94 : 1,
        duration: Duration(milliseconds: 120),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_pulse.value);
            return AnimatedContainer(
              duration: Duration(milliseconds: 300),
              width: 184,
              height: 184,
              padding: EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: on ? _brand : null,
                color: on ? null : _purple.withValues(alpha: .55),
                boxShadow: [
                  BoxShadow(
                    color: glow.withValues(alpha: (on ? .28 : .14) + .17 * t),
                    blurRadius: (on ? 40 : 24) + 22 * t,
                    spreadRadius: 2 + 4 * t,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: _surface, image: panelImage),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  SizedBox(width: 170, height: 170, child: CircularProgressIndicator(strokeWidth: 3, color: glow)),
                AnimatedSwitcher(
                  duration: Duration(milliseconds: 300),
                  transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                  child: on
                      ? ShaderMask(
                          key: ValueKey('on'),
                          shaderCallback: (r) => _brand.createShader(r),
                          child: Icon(Icons.power_settings_new_rounded, size: 76, color: Colors.white),
                        )
                      : Icon(Icons.power_settings_new_rounded, key: ValueKey('off'), size: 76, color: _purple),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

List<Color> get _protoColors => [const Color(0xFF6EA8FE), _muted, const Color(0xFFC6E36B)];

/// One server, Incy style: flag tile, name, coloured protocol line, ping on the right.
class _ServerRow extends StatelessWidget {
  final String flag, title;
  final List<String> parts;
  final String? subtitle; // instead of the protocol line
  final bool selected, inUse, tested;
  final int? ping;
  final VoidCallback onTap;
  const _ServerRow({
    required this.flag,
    required this.title,
    required this.parts,
    this.subtitle,
    required this.selected,
    required this.inUse,
    required this.tested,
    this.ping,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = ping;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
          decoration: BoxDecoration(
            color: selected ? _purple.withValues(alpha: .16) : _surface,
            image: panelImage,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? _purple : _line),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  flag,
                  style: TextStyle(
                    fontSize: flag.length <= 2 && flag.codeUnits.every((c) => c < 128) ? 14 : 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (inUse)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: _green, shape: BoxShape.circle),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (subtitle != null)
                      Text(subtitle!, style: TextStyle(color: _muted, fontSize: 13))
                    else
                      Text.rich(
                        TextSpan(
                          children: [
                            for (var i = 0; i < parts.length; i++) ...[
                              if (i > 0)
                                TextSpan(
                                  text: ' · ',
                                  style: TextStyle(color: _muted),
                                ),
                              TextSpan(
                                text: parts[i],
                                style: TextStyle(color: _protoColors[i < 2 ? i : 2]),
                              ),
                            ],
                          ],
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(scale: Tween(begin: .8, end: 1.0).animate(a), child: child),
                ),
                child: Text(
                  !tested ? '—' : (p == null ? 'n/a' : '$p мс'),
                  key: ValueKey('$tested$p'),
                  style: TextStyle(
                    fontSize: 14,
                    color: !tested ? _muted : (p == null ? _red : (p < 700 ? _green : (p < 1500 ? _purple : _red))),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _NavBar({required this.index, required this.onTap});

  static const _items = [
    (Icons.home_rounded, 'Главная'),
    (Icons.dns_rounded, 'Серверы'),
    (Icons.tune_rounded, 'Настройки'),
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _surface,
        image: panelImage,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onTap(i),
                borderRadius: BorderRadius.circular(18),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == index ? _purple.withValues(alpha: .18) : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: i == index ? _purple.withValues(alpha: .6) : Colors.transparent),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_items[i].$1, color: i == index ? _green : _muted),
                      const SizedBox(height: 2),
                      Text(_items[i].$2, style: TextStyle(fontSize: 12, color: i == index ? Colors.white : _muted)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
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
      decoration: BoxDecoration(
        color: _surface,
        image: panelImage,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color),
          ),
          if (left != null && !left.isNegative && sub.notice == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Осталось ${_left(left)}', style: TextStyle(color: _muted, fontSize: 13)),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onBot,
                  style: FilledButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: palette.onAccent,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Продлить', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: onBot,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _line),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Поддержка', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _d(DateTime t) => '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';

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
  final bool embedded; // a tab of the home screen (no app bar, nothing to pop)
  const SettingsPage({
    super.key,
    required this.settings,
    required this.update,
    required this.onCheckUpdate,
    required this.onInstall,
    this.embedded = false,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings get s => widget.settings;
  Update? update;
  bool checking = false;
  String? checked;
  final _taps = <DateTime>[]; // the secret: 7 taps on the version line within 3 s

  void _versionTap() {
    final now = DateTime.now();
    _taps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
    if (_taps.length < 7) return;
    _taps.clear();
    HapticFeedback.mediumImpact();
    _secretField();
  }

  Future<void> _secretField() async {
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('🤫'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
          decoration: InputDecoration(
            hintText: 'Код',
            filled: true,
            fillColor: _bg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _line),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Отмена', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text),
            child: Text('ОК', style: TextStyle(color: _purple)),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (code == null || code.trim().isEmpty || !mounted) return;
    final said = await runEgg(code);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(said ?? 'Ничего не произошло 👀')));
  }

  @override
  void initState() {
    super.initState();
    update = widget.update;
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(title, style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
  );

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: _surface,
      image: panelImage,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _line),
    ),
    child: Column(children: children),
  );

  Widget _radio<T>(String title, T value, T group, ValueChanged<T> onChanged, {String? subtitle}) => ListTile(
    onTap: () => setState(() => onChanged(value)),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(color: _muted, fontSize: 12)),
    trailing: Icon(
      value == group ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
      color: value == group ? _green : _muted,
    ),
  );

  Widget _switch(String title, String subtitle, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
    value: value,
    onChanged: (v) => setState(() => onChanged(v)),
    title: Text(title),
    subtitle: Text(subtitle, style: TextStyle(color: _muted, fontSize: 12)),
  );

  static const _protoHints = {
    'auto': 'Сам выбирает самый быстрый из работающих',
    'main': 'Основной, маскируется под обычный сайт',
    'grpc': 'Запасной, если основной режут',
  };

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (widget.embedded)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text('Настройки', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          ),
        _section('ПРОТОКОЛ'),
        _card([
          for (final e in protocols.entries)
            _radio(e.value, e.key, s.protocol, (v) => s.protocol = v, subtitle: _protoHints[e.key]),
        ]),
        _section('ПОДКЛЮЧЕНИЕ'),
        _card([
          _switch(
            'Автопереключение',
            'Если сервер или протокол перестал отвечать — сразу перейти на рабочий',
            s.autoSwitch,
            (v) => s.autoSwitch = v,
          ),
          _switch(
            'Российские сайты напрямую',
            'Госуслуги, банки и .ru открываются без VPN — быстрее и без блокировок',
            s.directRu,
            (v) => s.directRu = v,
          ),
          _switch(
            'Подключаться при запуске',
            'VPN включается сам, как только открываешь приложение',
            s.autoConnect,
            (v) => s.autoConnect = v,
          ),
          if (Platform.isAndroid)
            ListTile(
              onTap: Vpn.openSystemSettings,
              title: const Text('Постоянный VPN и блокировка без VPN'),
              subtitle: Text(
                'Системные настройки Android: «Постоянная VPN» и «Блокировать соединения без VPN»',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              trailing: Icon(Icons.open_in_new_rounded, color: _muted, size: 20),
            ),
        ]),
        _section('DNS'),
        _card([for (final e in dnsServers.entries) _radio(e.value.$1, e.key, s.dns, (v) => s.dns = v)]),
        _section('ПРИЛОЖЕНИЕ'),
        _card([
          ListTile(
            // no ripple, no hint: the secret field opens after 7 quick taps
            title: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _versionTap,
              child: Text('NetKings $appVersion'),
            ),
            subtitle: Text(
              update != null ? 'Доступна версия ${update!.version}' : (checked ?? 'Обновления проверяются сами'),
              style: TextStyle(color: update != null ? _green : _muted, fontSize: 12),
            ),
            trailing: update != null
                ? FilledButton(
                    onPressed: () {
                      if (!widget.embedded) Navigator.of(context).pop();
                      widget.onInstall();
                    },
                    style: FilledButton.styleFrom(backgroundColor: _purple, foregroundColor: palette.onAccent),
                    child: const Text('Обновить'),
                  )
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
                        : Text('Проверить', style: TextStyle(color: _purple)),
                  ),
          ),
        ]),
      ],
    );
    return widget.embedded
        ? list
        : Scaffold(
            appBar: AppBar(backgroundColor: _bg, title: const Text('Настройки')),
            body: list,
          );
  }
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
      const Text(
        'NetKings VPN',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        'Работает там, где другие не работают',
        textAlign: TextAlign.center,
        style: TextStyle(color: _muted, fontSize: 15),
      ),
      const SizedBox(height: 40),
      FilledButton.icon(
        onPressed: widget.onBot,
        icon: const Icon(Icons.send_rounded),
        label: const Text('Получить доступ в боте', style: TextStyle(fontWeight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: _purple,
          foregroundColor: palette.onAccent,
          minimumSize: const Size.fromHeight(52),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Пробный период 3 дня — бесплатно. В боте нажми «📲 Открыть в NetKings».',
        textAlign: TextAlign.center,
        style: TextStyle(color: _muted, fontSize: 13),
      ),
      const SizedBox(height: 32),
      Text('УЖЕ ЕСТЬ ССЫЛКА?', style: TextStyle(color: _muted, fontSize: 12, letterSpacing: 1.2)),
      const SizedBox(height: 10),
      TextField(
        controller: ctl,
        decoration: InputDecoration(
          hintText: 'https://…/sub/…',
          filled: true,
          fillColor: _surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _line),
          ),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: widget.busy ? null : () => widget.onLink(ctl.text),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: _line),
          minimumSize: const Size.fromHeight(48),
        ),
        child: widget.busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Добавить', style: TextStyle(color: Colors.white)),
      ),
      if (widget.message != null) ...[
        const SizedBox(height: 14),
        Text(
          widget.message!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _red),
        ),
      ],
    ],
  );
}
