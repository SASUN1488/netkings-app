import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/singbox.dart';
import 'src/subscription.dart';
import 'src/vpn.dart';

const _bg = Color(0xFF0E1014);
const _surface = Color(0xFF181B22);
const _line = Color(0xFF262A33);
const _gold = Color(0xFFF2B33D);
const _green = Color(0xFF3FCF8E);
const _muted = Color(0xFF8B93A3);
const _red = Color(0xFFF0616D);
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
          colorScheme: const ColorScheme.dark(primary: _gold, surface: _surface, error: _red),
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
  Subscription? sub;
  String country = 'auto';
  bool loading = true, refreshing = false;
  String? message;
  DateTime? _lastFetch;

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
    sub = await cachedSubscription();
    final link = await Vpn.initialLink();
    setState(() => loading = false);
    if (link != null) {
      await _importLink(link);
    } else if (sub != null) {
      unawaited(_refresh(silent: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // the bot may have extended the subscription meanwhile; at most once per 10 min
    if (s == AppLifecycleState.resumed && sub != null &&
        (_lastFetch == null || DateTime.now().difference(_lastFetch!) > const Duration(minutes: 10))) {
      _refresh(silent: true);
    }
  }

  void _onVpn() {
    if (vpn.error != null && vpn.state == VpnState.stopped) message = 'Не удалось подключиться: ${vpn.error}';
    setState(() {});
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
    setState(() => message = null);
    if (!await vpn.start(buildConfig(s, country))) {
      setState(() => message = vpn.error ?? 'Нужно разрешить VPN-подключение');
    }
  }

  /// new country / new servers while connected: stop, wait for it, start again
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
    await vpn.start(buildConfig(sub!, country));
  }

  Future<void> _pickCountry(String tag) async {
    if (tag == country) return;
    setState(() => country = tag);
    await Store.write('country', tag);
    await _restart();
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
      color: _gold,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(children: [
            const Icon(Icons.workspace_premium_rounded, color: _gold, size: 28),
            const SizedBox(width: 8),
            const Text('NetKings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: .3)),
            const Spacer(),
            IconButton(
              tooltip: 'Обновить подписку',
              onPressed: refreshing ? null : _refresh,
              icon: refreshing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, color: _muted),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: _muted),
              color: _surface,
              onSelected: (v) => v == 'logout' ? _logout() : null,
              itemBuilder: (_) => const [PopupMenuItem(value: 'logout', child: Text('Другая подписка'))],
            ),
          ]),
          const SizedBox(height: 36),
          Center(child: _PowerButton(on: on, busy: busy, onTap: busy ? null : _toggle)),
          const SizedBox(height: 20),
          Center(
            child: Text(statusText,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: on ? _green : Colors.white)),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(on ? _countryLabel(s) : 'Нажми, чтобы подключиться',
                style: const TextStyle(color: _muted, fontSize: 14)),
          ),
          const SizedBox(height: 32),
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

  String _countryLabel(Subscription s) {
    if (country == 'auto') return 'Самый быстрый сервер';
    final c = s.countries.where((c) => c.tag == country);
    return c.isEmpty ? 'Самый быстрый сервер' : _flag(c.first) + c.first.name;
  }
}

class _PowerButton extends StatelessWidget {
  final bool on, busy;
  final VoidCallback? onTap;
  const _PowerButton({required this.on, required this.busy, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = on ? _green : _gold;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 184,
        height: 184,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _surface,
          border: Border.all(color: color.withValues(alpha: on ? 1 : .55), width: 3),
          boxShadow: [BoxShadow(color: color.withValues(alpha: on ? .35 : .12), blurRadius: on ? 48 : 24, spreadRadius: 2)],
        ),
        child: Stack(alignment: Alignment.center, children: [
          if (busy) SizedBox(width: 170, height: 170, child: CircularProgressIndicator(strokeWidth: 3, color: color)),
          Icon(Icons.power_settings_new_rounded, size: 76, color: color),
        ]),
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
            color: selected ? _gold.withValues(alpha: .14) : _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? _gold : _line),
          ),
          child: Text(label, style: TextStyle(fontSize: 15, color: selected ? _gold : Colors.white)),
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
      if (left.inDays < 3) color = _gold;
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
              style: FilledButton.styleFrom(backgroundColor: _gold, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(44)),
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
          const Icon(Icons.workspace_premium_rounded, color: _gold, size: 64),
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
            style: FilledButton.styleFrom(backgroundColor: _gold, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(52)),
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
