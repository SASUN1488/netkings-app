import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/appearance.dart';
import 'src/idea.dart';
import 'src/monitor.dart';
import 'src/ping.dart';
import 'src/power_button.dart';
import 'src/secrets.dart';
import 'src/settings.dart';
import 'src/singbox.dart';
import 'src/subscription.dart';
import 'src/update.dart';
import 'src/vpn.dart';

// colours come from the palette (src/appearance.dart): theme, accent, wallpaper / easter-egg pictures
Color get _bg => palette.bg;
Color get _surface => palette.surface;
Color get _high => palette.high;
Color get _line => palette.line;
Color get _purple => palette.accent;
Color get _green => palette.accent2;
Color get _muted => palette.muted;
Color get _fg => palette.fg;
const _red = Color(0xFFF0616D);
LinearGradient get _brand =>
    LinearGradient(colors: [_green, _purple], begin: Alignment.topLeft, end: Alignment.bottomRight);
const _shopBot = 'https://t.me/NetKingsvpn_bot';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadEggs();
  await loadAppearance();
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in [('Google Sans Flex', 'GoogleSansFlex'), ('Nunito', 'Nunito')]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString('assets/fonts/$file-OFL.txt'));
    }
  });
  runApp(const NetKingsApp());
}

/// Material 3 theme for [b] from the user's appearance: colours, font (bold + rounded by default).
ThemeData appTheme(Brightness b) {
  final s = schemeFor(b);
  final base = ThemeData(
    colorScheme: s,
    useMaterial3: true,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    brightness: b,
  );
  final bold = boldText, v = fontVariations;
  TextStyle? f(TextStyle? t, FontWeight w) => t?.copyWith(fontVariations: v, fontWeight: bold ? w : null);
  final t = base.textTheme;
  final text = t.copyWith(
    displayLarge: f(t.displayLarge, FontWeight.w700),
    displayMedium: f(t.displayMedium, FontWeight.w700),
    displaySmall: f(t.displaySmall, FontWeight.w700),
    headlineLarge: f(t.headlineLarge, FontWeight.w800),
    headlineMedium: f(t.headlineMedium, FontWeight.w800),
    headlineSmall: f(t.headlineSmall, FontWeight.w800),
    titleLarge: f(t.titleLarge, FontWeight.w800),
    titleMedium: f(t.titleMedium, FontWeight.w700),
    titleSmall: f(t.titleSmall, FontWeight.w700),
    bodyLarge: f(t.bodyLarge, FontWeight.w600),
    bodyMedium: f(t.bodyMedium, FontWeight.w600),
    bodySmall: f(t.bodySmall, FontWeight.w500),
    labelLarge: f(t.labelLarge, FontWeight.w700),
    labelMedium: f(t.labelMedium, FontWeight.w600),
    labelSmall: f(t.labelSmall, FontWeight.w600),
  );
  return base.copyWith(
    scaffoldBackgroundColor: look.value != null ? Colors.transparent : s.surface,
    textTheme: text,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: s.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(color: s.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    // Material Symbols a bit heavier, to sit with the bold text
    iconTheme: IconThemeData(color: s.onSurfaceVariant, weight: 500, opticalSize: 24),
    dialogTheme: DialogThemeData(backgroundColor: s.surfaceContainerHigh),
    popupMenuTheme: PopupMenuThemeData(color: s.surfaceContainerHigh),
  );
}

class NetKingsApp extends StatefulWidget {
  const NetKingsApp({super.key});

  @override
  State<NetKingsApp> createState() => _NetKingsAppState();
}

class _NetKingsAppState extends State<NetKingsApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // theme "Авто": the phone switched light / dark
  @override
  void didChangePlatformBrightness() {
    if (appearance.value.mode == 'system') colorsVersion.value++;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([look, appearance, colorsVersion]),
    builder: (context, _) {
      final b = brightness;
      return MaterialApp(
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
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
        home: const Home(),
      );
    },
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
  bool editing = false; // the home screen's edit mode: blocks are moved / hidden right on it
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
    appearance.addListener(_onEgg);
    colorsVersion.addListener(_onEgg);
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
      if (isDirectPing(settings.pingMethod)) unawaited(_testPings());
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
              pingMethod: settings.pingMethod,
              entryOf: _entryOf,
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
      // numbers from the tunnel are meaningless without it: "—" until the next connect (direct ones stay)
      if (!isDirectPing(settings.pingMethod)) pings = {};
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
    if (appearance.value.haptics) HapticFeedback.mediumImpact();
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

  /// The entry server (host, port) a server connects to.
  (String, int)? _entryOf(String leaf) {
    final o = _outboundsByTag[leaf];
    final h = o?['server'], port = o?['server_port'];
    return h is String && port is int ? (h, port) : null;
  }

  /// Pings for the server list. TCP / ICMP go straight to each server, so they work before connecting too
  /// (another VPN app being on makes them meaningless — the user picked them). The other ways need the core:
  /// a real request through every server (its delay test).
  Future<void> _testPings() async {
    final m = monitor;
    final method = settings.pingMethod;
    final direct = isDirectPing(method);
    if (testing || (m == null && !direct)) return;
    setState(() => testing = true);
    final Map<String, int?> r;
    if (direct) {
      final tags = _leaves;
      final byHost = <String, Future<int?>>{}; // one ICMP ping per entry address, not per server
      final res = await Future.wait([
        for (final t in tags)
          switch (_entryOf(t)) {
            null => Future.value(null),
            final e => method == 'icmp' ? byHost.putIfAbsent(e.$1, () => icmpPing(e.$1)) : tcpPingMedian(e.$1, e.$2),
          },
      ]);
      r = {for (var i = 0; i < tags.length; i++) tags[i]: res[i]};
    } else {
      r = await m!.testServers(_leaves, {for (final l in _leaves) l: leafPingPort(sub!, l)});
    }
    if (mounted) {
      setState(() {
        if (direct || monitor == m) pings = r; // disconnected meanwhile: keep "—"
        testing = false;
      });
    }
  }

  bool get _canPing => !testing && (monitor != null || isDirectPing(settings.pingMethod));

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
    } else if ((settings.autoSwitch != before.autoSwitch || settings.pingMethod != before.pingMethod) &&
        monitor != null) {
      // the watchdog reads these at start: renew it
      monitor!.dispose();
      monitor = null;
      _onVpn();
    }
    if (settings.pingMethod != before.pingMethod) {
      pings = {};
      if (_canPing) unawaited(_testPings());
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
    appearance.removeListener(_onEgg);
    colorsVersion.removeListener(_onEgg);
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
      canPop: tab == 0 && !editing, // Android back: out of the edit mode / to the home tab first
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        editing ? setState(() => editing = false) : _goTab(0);
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
                  subUrl: s.url,
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
                  onEditHome: () async {
                    await _goTab(0);
                    if (mounted) setState(() => editing = true);
                  },
                ),
                _ => editing ? _editMain(s) : _main(s),
              },
            ),
          ),
        ),
        bottomNavigationBar: editing ? null : _NavBar(index: tab, onTap: _goTab),
      ),
    );
  }

  bool get _on => vpn.state == VpnState.started;

  Widget _header() => Row(
    children: [
      Image.asset('assets/icon/icon.png', width: 30, height: 30, filterQuality: FilterQuality.medium),
      SizedBox(width: 10),
      Text('NetKings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: .2)),
      SizedBox(width: 12),
      // speed on the title's line, pushed to the right
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _SpeedBar(monitor: _on ? monitor : null),
          ),
        ),
      ),
      PopupMenuButton<String>(
        icon: Icon(Symbols.more_vert_rounded, color: _muted),
        color: _surface,
        onSelected: (v) => v == 'logout' ? _logout() : null,
        itemBuilder: (_) => [PopupMenuItem(value: 'logout', child: Text('Другая подписка'))],
      ),
    ],
  );

  /// One movable block of the home screen; [preview] = inside the edit mode (the server list folded).
  Widget _block(Subscription s, String id, {bool preview = false}) {
    final st = vpn.state;
    final busy = st == VpnState.starting || st == VpnState.stopping;
    final statusText = switch (st) {
      VpnState.started => 'Подключено',
      VpnState.starting => 'Подключаю…',
      VpnState.stopping => 'Отключаю…',
      VpnState.stopped => 'Не подключено',
    };
    return switch (id) {
      'power' => _powerBlock(s, st, _on, busy, statusText),
      'servers' => _serversBlock(preview: preview),
      _ => _SubscriptionCard(sub: s, onBot: () => _open(s.bot.isNotEmpty ? s.bot : _shopBot)),
    };
  }

  Widget _main(Subscription s) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: _purple,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          _header(),
          if (update != null) ...[
            SizedBox(height: 12),
            _UpdateCard(update: update!, progress: updateProgress, onInstall: _install),
          ],
          // the blocks in the order the user set in the edit mode
          for (final id in appearance.value.blocks)
            if (id == 'power' || !appearance.value.hidden.contains(id)) ...[
              SizedBox(height: id == 'power' ? 28 : 20),
              _block(s, id),
            ],
          if (message != null) ...[SizedBox(height: 16), Text(message!, style: TextStyle(color: _red, fontSize: 14))],
        ],
      ),
    );
  }

  /// Edit mode: the real blocks (a live preview) in a reorderable list, gently jiggling.
  Widget _editMain(Subscription s) => _HomeEditor(
    header: _header(),
    build: (id) => _block(s, id, preview: true),
    onDone: () => setState(() => editing = false),
  );

  Widget _powerBlock(Subscription s, VpnState st, bool on, bool busy, String statusText) => Column(
    children: [
      // holding the button 1.5 s turns «Автовыбор» on (a tap still connects / disconnects: the long press
      // wins the gesture only when the finger stays that long)
      RawGestureDetector(
        gestures: {
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 1500)),
            (r) => r.onLongPress = _holdAutoPick,
          ),
        },
        child: PowerButton(
          style: appearance.value.button,
          on: on,
          busy: busy,
          stopping: st == VpnState.stopping,
          onTap: busy ? null : _toggle,
        ),
      ),
      SizedBox(height: 20),
      AnimatedSwitcher(
        duration: Duration(milliseconds: 300),
        child: Text(
          statusText,
          key: ValueKey(statusText),
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on ? _green : _fg),
        ),
      ),
      SizedBox(height: 6),
      Text(
        on
            ? _onLabel(s)
            : (appearance.value.button == 'slide' ? 'Проведи, чтобы подключиться' : 'Нажми, чтобы подключиться'),
        textAlign: TextAlign.center,
        style: TextStyle(color: _muted, fontSize: 14),
      ),
      if (!autoPick) ...[
        SizedBox(height: 2),
        Text(
          'Зажми кнопку, чтобы вернуть автовыбор',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted.withValues(alpha: .7), fontSize: 12),
        ),
      ],
    ],
  );

  Widget _serversBlock({bool preview = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          InkWell(
            onTap: _toggleCollapsed,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Text(
                    'Серверы',
                    style: TextStyle(color: _fg, fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  Icon(collapsed ? Symbols.expand_more_rounded : Symbols.expand_less_rounded, color: _muted, size: 22),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Обновить подписку',
            visualDensity: VisualDensity.compact,
            onPressed: refreshing ? null : _refresh,
            icon: refreshing
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Symbols.sync_rounded, color: _muted, size: 20),
          ),
          IconButton(
            tooltip: 'Проверить пинг',
            visualDensity: VisualDensity.compact,
            onPressed: _canPing ? _testPings : null,
            icon: testing
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Symbols.speed_rounded, color: _muted, size: 20),
          ),
          Spacer(),
          _pingChip(),
        ],
      ),
      SizedBox(height: 4),
      AnimatedSize(
        duration: Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: Column(children: collapsed || preview ? [_currentRow()] : _serverRows()),
      ),
    ],
  );

  /// Holding the connect button: «Автовыбор» back on.
  Future<void> _holdAutoPick() async {
    HapticFeedback.heavyImpact();
    if (autoPick) {
      _toast('Автовыбор уже включён');
      return;
    }
    await _setAutoPick(true);
    if (mounted) _toast('Автовыбор включён — подключаюсь к самому быстрому серверу');
  }

  /// The ping of the server in use (connected) or of the picked one (TCP / ICMP before connecting), as a
  /// small chip in the servers' header; NK Ping also shows its parts.
  Widget _pingChip() {
    final m = monitor;
    String? text, parts;
    Color color = _muted;
    if (m != null) {
      if (m.ping == null && m.misses < 2) return SizedBox.shrink();
      text = _pingText(m);
      color = _pingColor(m);
      if (m.misses == 0 && m.ping != null && m.pingToServer != null) {
        final r = PingResult(m.ping!, m.pingToServer);
        parts = '${r.toServer} + ${r.beyond}';
      }
    } else if (_manual && pings.containsKey(server)) {
      final p = pings[server];
      text = p == null ? 'нет ответа' : '$p мс';
      color = p == null ? _red : _green;
    }
    if (text == null) return SizedBox.shrink();
    final chip = AnimatedContainer(
      duration: Duration(milliseconds: 250),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.network_ping_rounded, size: 16, color: color),
          SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w800),
          ),
          if (parts != null) ...[SizedBox(width: 6), Text(parts, style: TextStyle(color: _muted, fontSize: 12))],
        ],
      ),
    );
    return parts == null
        ? chip
        : Tooltip(
            // NK Ping: where the time goes — the user's own internet or the VPN
            message:
                '${m!.pingToServer} мс — от тебя до сервера (твой интернет)\n${PingResult(m.ping!, m.pingToServer).beyond} мс — дальше по VPN до сайта',
            triggerMode: TooltipTriggerMode.tap,
            child: chip,
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
                onPressed: _canPing ? _testPings : null,
                icon: testing
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Symbols.speed_rounded, color: _muted),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              autoPick
                  ? 'Сейчас включён автовыбор. Нажми на сервер — буду подключаться только к нему.'
                  : 'Подключаюсь только к выбранному серверу. Вернуть автовыбор — зажми кнопку подключения на главной.',
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
        showPing: false,
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
      showPing: false, // the chip in the header shows it
      onTap: _toggleCollapsed,
    );
  }

  /// Every server, Incy style. Автовыбор on: the one the core uses has a green dot; a tap = that server only.
  /// The server in use shows the live ping (the same number as the chip); the others the last list test.
  List<Widget> _serverRows() {
    final m = monitor;
    final live = m != null && m.ping != null && m.misses < 2 ? m.ping : null;
    final obs = _outboundsByTag;
    return [
      for (final l in _leaves)
        _ServerRow(
          flag: _flagOf(l),
          title: _leafName(l),
          parts: _protoParts(obs[l]),
          selected: _manual && server == l,
          inUse: m?.leaf == l,
          tested: (m?.leaf == l && live != null) || pings.containsKey(l),
          ping: m?.leaf == l && live != null ? live : pings[l],
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

/// Download / upload speed: two small chips on the header line.
class _SpeedBar extends StatelessWidget {
  final Monitor? monitor;
  const _SpeedBar({this.monitor});

  @override
  Widget build(BuildContext context) {
    final m = monitor;
    Widget chip(IconData icon, String value, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: _surface, image: panelImage, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: m == null ? _muted : color),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: m == null ? _muted : _fg),
          ),
        ],
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        chip(Symbols.arrow_downward_rounded, m == null ? '—' : formatSpeed(m.down), _green),
        const SizedBox(width: 6),
        chip(Symbols.arrow_upward_rounded, m == null ? '—' : formatSpeed(m.up), _purple),
      ],
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

/// The home screen's edit mode: its real blocks (so it is a live preview) in a reorderable list. Blocks jiggle
/// a little; the one being dragged lifts (bigger, with a shadow) and the others slide out of its way. Drag by
/// the name chip (or a long press anywhere on a block), the eye hides / shows a block. Saved at once.
class _HomeEditor extends StatefulWidget {
  final Widget header;
  final Widget Function(String id) build;
  final VoidCallback onDone;
  const _HomeEditor({required this.header, required this.build, required this.onDone});

  @override
  State<_HomeEditor> createState() => _HomeEditorState();
}

class _HomeEditorState extends State<_HomeEditor> with SingleTickerProviderStateMixin {
  late final _jiggle = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _jiggle.dispose();
    super.dispose();
  }

  Appearance get _a => appearance.value;

  Future<void> _set(void Function(Appearance a) change) async {
    final a = _a.copy();
    change(a);
    await saveAppearance(a);
    if (mounted) setState(() {});
  }

  Widget _frame(String id, int i) {
    final hidden = _a.hidden.contains(id);
    return Padding(
      key: ValueKey(id),
      padding: const EdgeInsets.only(bottom: 14),
      child: AnimatedBuilder(
        animation: _jiggle,
        // neighbours tilt the other way, like icons on a phone's home screen in edit mode
        builder: (context, child) =>
            Transform.rotate(angle: (i.isEven ? 1 : -1) * (_jiggle.value - .5) * .008, child: child),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: hidden ? .45 : 1,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
            decoration: BoxDecoration(
              color: _purple.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _purple.withValues(alpha: hidden ? .25 : .6), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                        decoration: BoxDecoration(color: _high, borderRadius: BorderRadius.circular(14)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Symbols.drag_indicator_rounded, size: 18, color: _fg),
                            const SizedBox(width: 4),
                            Text(blockNames[id]!, style: TextStyle(fontSize: 13, color: _fg)),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (hidden)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text('скрыт', style: TextStyle(color: _muted, fontSize: 12)),
                      ),
                    if (id == 'power')
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Symbols.lock_rounded, size: 18, color: _muted),
                      )
                    else
                      IconButton.filledTonal(
                        tooltip: hidden ? 'Показать' : 'Скрыть',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _set((a) => hidden ? a.hidden.remove(id) : a.hidden.add(id));
                        },
                        icon: Icon(hidden ? Symbols.visibility_off_rounded : Symbols.visibility_rounded, size: 20),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                // a preview: nothing inside reacts to taps while editing
                IgnorePointer(child: widget.build(id)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: widget.header),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
        child: Row(
          children: [
            Icon(Symbols.edit_rounded, color: _purple, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Режим редактирования', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            TextButton(
              onPressed: () => _set((a) {
                a.blocks = blockNames.keys.toList();
                a.hidden = {};
              }),
              child: const Text('Сбросить'),
            ),
            FilledButton(onPressed: widget.onDone, child: const Text('Готово')),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          'Перетаскивай блоки за название, глаз — скрыть или показать',
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ),
      Expanded(
        child: ReorderableListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          buildDefaultDragHandles: false,
          onReorderStart: (_) => HapticFeedback.mediumImpact(),
          onReorderItem: (from, to) => _set((a) => a.blocks.insert(to, a.blocks.removeAt(from))),
          // the dragged block lifts: a little bigger, a coloured shadow
          proxyDecorator: (child, _, anim) => AnimatedBuilder(
            animation: anim,
            builder: (context, c) {
              final t = Curves.easeOutBack.transform(anim.value);
              return Transform.scale(
                scale: 1 + .04 * t,
                child: Material(
                  color: Colors.transparent,
                  elevation: 14 * anim.value,
                  shadowColor: _purple.withValues(alpha: .6),
                  borderRadius: BorderRadius.circular(28),
                  child: c,
                ),
              );
            },
            child: child,
          ),
          children: [for (var i = 0; i < _a.blocks.length; i++) _frame(_a.blocks[i], i)],
        ),
      ),
    ],
  );
}

class _UpdateCard extends StatelessWidget {
  final Update update;
  final double? progress;
  final VoidCallback onInstall;
  const _UpdateCard({required this.update, required this.progress, required this.onInstall});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: _purple.withValues(alpha: .16)),
    child: Row(
      children: [
        Icon(Symbols.system_update_rounded, color: _green),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Доступна версия ${update.version}', style: TextStyle(fontWeight: FontWeight.w800)),
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

List<Color> get _protoColors => [const Color(0xFF6EA8FE), _muted, const Color(0xFFC6E36B)];

/// One server, Incy style: flag tile, name, coloured protocol line, ping on the right.
class _ServerRow extends StatelessWidget {
  final String flag, title;
  final List<String> parts;
  final String? subtitle; // instead of the protocol line
  final bool selected, inUse, tested;
  final bool showPing;
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
    this.showPing = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = ping;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(selected ? 28 : 20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
          // Material 3 Expressive: the picked server is tonal and rounder
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(_purple.withValues(alpha: .22), _surface) : _surface,
            image: panelImage,
            borderRadius: BorderRadius.circular(selected ? 28 : 20),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _high, borderRadius: BorderRadius.circular(14)),
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
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
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
              if (showPing) const SizedBox(width: 8),
              if (showPing)
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
    (Symbols.home_rounded, Symbols.home_rounded, 'Главная'),
    (Symbols.dns_rounded, Symbols.dns_rounded, 'Серверы'),
    (Symbols.tune_rounded, Symbols.tune_rounded, 'Настройки'),
  ];

  /// Material 3 navigation bar (pill indicator behind the icon); on a wallpaper it is see-through.
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: _surface, image: panelImage),
    child: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onTap,
      backgroundColor: Colors.transparent,
      indicatorColor: _purple.withValues(alpha: .28),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        for (final i in _items)
          NavigationDestination(
            icon: Icon(i.$1, color: _muted),
            selectedIcon: Icon(i.$2, color: _fg, fill: 1),
            label: i.$3,
          ),
      ],
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
    Color color = _fg;
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
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: _surface, image: panelImage, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color),
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
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Продлить', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onBot,
                  style: FilledButton.styleFrom(
                    backgroundColor: _high,
                    foregroundColor: _fg,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Поддержка', style: TextStyle(fontWeight: FontWeight.w700)),
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
  final String subUrl; // «Предложить иконку» sends to the subscription's server
  final Update? update;
  final Future<Update?> Function() onCheckUpdate;
  final VoidCallback onInstall;
  final VoidCallback? onEditHome; // Главный экран → «Режим редактирования»
  final bool embedded; // a tab of the home screen (no app bar, nothing to pop)
  const SettingsPage({
    super.key,
    required this.settings,
    required this.subUrl,
    required this.update,
    required this.onCheckUpdate,
    required this.onInstall,
    this.onEditHome,
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
  bool sending = false; // an icon idea is on its way

  Appearance get _a => appearance.value;

  /// Appearance changes apply at once (they do not touch the core).
  Future<void> _setA(void Function(Appearance a) change) async {
    final a = _a.copy();
    change(a);
    await saveAppearance(a);
    if (mounted) setState(() {});
  }

  void _say(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  Widget _label(String t, [String? sub]) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(t, style: TextStyle(fontSize: 16, color: _fg)),
      if (sub != null) Text(sub, style: TextStyle(color: _muted, fontSize: 12)),
    ],
  );

  Widget _themeRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Тема'),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [for (final e in modes.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {_a.mode},
            onSelectionChanged: (v) => _setA((a) => a.mode = v.first),
          ),
        ),
      ],
    ),
  );

  Widget _colorsRow() {
    final items = <(String, String, Color?)>[
      for (final e in seeds.entries) (e.key, e.value.$1, e.value.$2),
      if (hasSystemColors) ('system', 'Material You', null),
      if (hasOwnWallpaper) ('wallpaper', 'Из обоев', null),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Цвета'),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 12, children: [for (final it in items) _colorDot(it)]),
        ],
      ),
    );
  }

  /// A colour choice; the picked one morphs from a circle into a rounded square (M3 Expressive).
  Widget _colorDot((String, String, Color?) it) {
    final sel = _a.colors == it.$1;
    final l = look.value;
    return InkWell(
      onTap: () => _setA((a) => a.colors = it.$1),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 70,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutBack,
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(sel ? 15 : 24),
                color: it.$1 == 'netkings' ? null : it.$3,
                gradient: it.$1 == 'netkings'
                    ? const LinearGradient(colors: [Color(0xFF2EE59D), Color(0xFF9D6BFF)])
                    : (it.$1 == 'system'
                          ? const SweepGradient(
                              colors: [
                                Color(0xFFE5484D),
                                Color(0xFFFFC53D),
                                Color(0xFF3DBE5C),
                                Color(0xFF4C7DFF),
                                Color(0xFFE5484D),
                              ],
                            )
                          : null),
                image: it.$1 == 'wallpaper' && l != null ? DecorationImage(image: l.image, fit: BoxFit.cover) : null,
              ),
              child: sel ? const Icon(Symbols.check_rounded, color: Colors.white) : null,
            ),
            const SizedBox(height: 4),
            Text(
              it.$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: sel ? _fg : _muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wallpaperRow() {
    final l = look.value;
    final own = hasOwnWallpaper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _high,
                  borderRadius: BorderRadius.circular(16),
                  image: l != null ? DecorationImage(image: l.image, fit: BoxFit.cover) : null,
                ),
                child: l == null ? Icon(Symbols.wallpaper_rounded, color: _muted) : null,
              ),
              const SizedBox(width: 14),
              Expanded(child: _label('Обои', own ? 'Своя картинка' : (l != null ? 'Секретная тема 🤫' : 'Без обоев'))),
              if (l != null)
                IconButton(
                  tooltip: 'Убрать обои',
                  onPressed: () async {
                    await clearWallpaper();
                    if (mounted) setState(() {});
                  },
                  icon: Icon(Symbols.close_rounded, color: _muted),
                ),
              FilledButton.tonal(
                onPressed: () async {
                  final t = await pickWallpaper();
                  if (!mounted) return;
                  setState(() {});
                  _say(t);
                },
                child: Text(l == null ? 'Выбрать' : 'Сменить'),
              ),
            ],
          ),
          if (own)
            Row(
              children: [
                Icon(Symbols.brightness_6_rounded, size: 18, color: _muted),
                Expanded(
                  child: Slider(
                    value: _a.wallDim,
                    max: .85,
                    // live preview while dragging; saved once at the end
                    onChanged: (v) => appearance.value = _a.copy()..wallDim = v,
                    onChangeEnd: (v) => _setA((a) => a.wallDim = v),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _fontRows() => Column(
    children: [
      for (final e in fonts.entries)
        ListTile(
          onTap: () async {
            // «Свой»: a file first (again when it is already on = another file)
            if (e.key == 'custom' && (_a.fontFile == null || _a.font == 'custom')) {
              final t = await pickFont();
              if (mounted) _say(t);
              return;
            }
            await _setA((a) => a.font = e.key);
          },
          title: Text(
            e.value.$1,
            style: switch (e.key) {
              'flex' => const TextStyle(
                fontFamily: 'GoogleSansFlex',
                fontFamilyFallback: ['Nunito'],
                fontVariations: [FontVariation('ROND', 100)],
                fontWeight: FontWeight.w800,
              ),
              'flex_plain' => const TextStyle(
                fontFamily: 'GoogleSansFlex',
                fontVariations: [],
                fontWeight: FontWeight.w500,
              ),
              _ => null,
            },
          ),
          subtitle: Text(
            e.key == 'custom' && _a.fontFile != null ? 'Свой файл · нажми ещё раз, чтобы сменить' : e.value.$2,
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          trailing: Icon(
            _a.font == e.key ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
            color: _a.font == e.key ? _green : _muted,
          ),
        ),
    ],
  );

  Widget _buttonPicker() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(left: 4), child: _label('Кнопка подключения')),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: [
            for (final e in buttons.entries)
              InkWell(
                onTap: () => _setA((a) => a.button = e.key),
                borderRadius: BorderRadius.circular(24),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
                  decoration: BoxDecoration(
                    color: _a.button == e.key ? Color.alphaBlend(_purple.withValues(alpha: .22), _bg) : _bg,
                    borderRadius: BorderRadius.circular(_a.button == e.key ? 28 : 18),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: IgnorePointer(
                          child: FittedBox(child: PowerButton(style: e.key, on: false, busy: false)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(e.value, style: TextStyle(fontSize: 13, color: _a.button == e.key ? _fg : _muted)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Future<void> _suggestIcon() async {
    final p = await pickIdeaPicture();
    if (p == null || !mounted) return;
    if (p.startsWith('!')) return _say(p.substring(1));
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Отправить картинку?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.file(File(p), height: 160, fit: BoxFit.contain),
            ),
            const SizedBox(height: 14),
            Text(
              'Она уйдёт команде NetKings. Если понравится — появится как иконка в одном из следующих обновлений.',
              style: TextStyle(color: _muted, fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Отправить')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => sending = true);
    final t = await sendIdea(widget.subUrl, p);
    if (!mounted) return;
    setState(() => sending = false);
    _say(t);
  }

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
    padding: const EdgeInsets.fromLTRB(24, 26, 24, 10),
    child: Text(
      title,
      style: TextStyle(color: _purple, fontSize: 14, fontWeight: FontWeight.w800),
    ),
  );

  /// Material 3 Expressive grouped list: rows are separate tonal tiles, big radius on the group's ends.
  Widget _card(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          Container(
            margin: EdgeInsets.only(top: i == 0 ? 0 : 3),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: _surface,
              image: panelImage,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(i == 0 ? 24 : 6),
                bottom: Radius.circular(i == children.length - 1 ? 24 : 6),
              ),
            ),
            child: Material(type: MaterialType.transparency, child: children[i]),
          ),
      ],
    ),
  );

  Widget _radio<T>(String title, T value, T group, ValueChanged<T> onChanged, {String? subtitle, String? badge}) =>
      ListTile(
        onTap: () => setState(() => onChanged(value)),
        title: badge == null
            ? Text(title)
            : Row(
                children: [
                  Text(title),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _green.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(color: _green, fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
        subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(color: _muted, fontSize: 12)),
        trailing: Icon(
          value == group ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
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
        _section('Протокол'),
        _card([
          for (final e in protocols.entries)
            _radio(e.value, e.key, s.protocol, (v) => s.protocol = v, subtitle: _protoHints[e.key]),
        ]),
        _section('Подключение'),
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
              trailing: Icon(Symbols.open_in_new_rounded, color: _muted, size: 20),
            ),
        ]),
        _section('DNS'),
        _card([for (final e in dnsServers.entries) _radio(e.value.$1, e.key, s.dns, (v) => s.dns = v)]),
        _section('Пинг'),
        _card([
          for (final e in pingMethods.entries)
            _radio(
              e.value.$1,
              e.key,
              s.pingMethod,
              (v) => s.pingMethod = v,
              subtitle: e.value.$2,
              badge: e.key == 'nk' ? 'наш' : null,
            ),
        ]),
        _section('Оформление'),
        _card([_themeRow(), _colorsRow(), _wallpaperRow(), _buttonPicker()]),
        _section('Шрифт'),
        _card([_fontRows()]),
        _section('Главный экран'),
        _card([
          ListTile(
            onTap: widget.onEditHome,
            leading: Icon(Symbols.edit_rounded, color: _purple),
            title: const Text('Режим редактирования'),
            subtitle: Text(
              'Переставляй и скрывай блоки прямо на главном экране',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            trailing: Icon(Symbols.chevron_right_rounded, color: _muted),
          ),
        ]),
        _section('Приложение'),
        _card([
          SwitchListTile(
            value: _a.haptics,
            onChanged: (v) => _setA((a) => a.haptics = v),
            title: const Text('Вибрация'),
            subtitle: Text('Лёгкий отклик при подключении', style: TextStyle(color: _muted, fontSize: 12)),
          ),
          ListTile(
            onTap: sending ? null : _suggestIcon,
            leading: Icon(Symbols.add_photo_alternate_rounded, color: _purple),
            title: const Text('Предложить иконку'),
            subtitle: Text(
              'Пришли свою картинку — лучшие добавим в обновлении',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            trailing: sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
          ),
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
        child: const Icon(Symbols.workspace_premium_rounded, color: Colors.white, size: 64),
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
        icon: const Icon(Symbols.send_rounded),
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
            : Text('Добавить', style: TextStyle(color: _fg)),
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
