import 'dart:math';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'appearance.dart';
import 'secrets.dart';

/// The connect button in the style picked in Оформление → Кнопка подключения.
/// [onTap] null = not pressable (busy, or a preview in the settings).
class PowerButton extends StatelessWidget {
  final String style;
  final bool on, busy;
  final bool stopping; // busy going off (busy alone = connecting)
  final VoidCallback? onTap;
  final double scale; // previews in the settings are smaller
  const PowerButton({
    super.key,
    required this.style,
    required this.on,
    required this.busy,
    this.stopping = false,
    this.onTap,
    this.scale = 1,
  });

  @override
  Widget build(BuildContext context) => switch (style) {
    'shape' => _ShapeButton(on: on, busy: busy, onTap: onTap, scale: scale),
    'pill' => _PillButton(on: on, busy: busy, stopping: stopping, onTap: onTap, scale: scale),
    'slide' => _SlideButton(on: on, busy: busy, stopping: stopping, onTap: onTap, scale: scale),
    _ => _GlowButton(on: on, busy: busy, onTap: onTap, scale: scale),
  };
}

LinearGradient get _brand =>
    LinearGradient(colors: [palette.accent2, palette.accent], begin: Alignment.topLeft, end: Alignment.bottomRight);

/// Repeats [c] while connected / connecting (faster), eases back to 0 when off.
mixin _Pulse<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  bool get pulseOn;
  bool get pulseFast;

  void syncPulse() {
    final d = Duration(milliseconds: pulseFast ? 900 : 2400);
    if (pulseOn || pulseFast) {
      if (pulse.duration != d || !pulse.isAnimating) {
        pulse.duration = d;
        pulse.repeat(reverse: true);
      }
    } else if (pulse.isAnimating || pulse.value != 0) {
      pulse.stop();
      pulse.animateTo(0, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void initState() {
    super.initState();
    syncPulse();
  }

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    syncPulse();
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }
}

/// A press shrinks the child a little.
class _Press extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;
  const _Press({required this.onTap, required this.child});

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.onTap != null,
    child: GestureDetector(
      onTap: widget.onTap,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(scale: _down ? .94 : 1, duration: const Duration(milliseconds: 120), child: widget.child),
    ),
  );
}

/// «Сияние»: a ring with a glow that slowly breathes when connected and pulses faster while connecting.
class _GlowButton extends StatefulWidget {
  final bool on, busy;
  final VoidCallback? onTap;
  final double scale;
  const _GlowButton({required this.on, required this.busy, this.onTap, required this.scale});

  @override
  State<_GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<_GlowButton> with SingleTickerProviderStateMixin, _Pulse {
  @override
  bool get pulseOn => widget.on;
  @override
  bool get pulseFast => widget.busy;

  @override
  Widget build(BuildContext context) {
    final p = palette, on = widget.on, busy = widget.busy, k = widget.scale;
    final glow = on ? p.accent2 : p.accent;
    return _Press(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(pulse.value);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 184 * k,
            height: 184 * k,
            padding: EdgeInsets.all(3 * k),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: on ? _brand : null,
              color: on ? null : p.accent.withValues(alpha: .55),
              boxShadow: [
                BoxShadow(
                  color: glow.withValues(alpha: (on ? .28 : .14) + .17 * t),
                  blurRadius: ((on ? 40 : 24) + 22 * t) * k,
                  spreadRadius: (2 + 4 * t) * k,
                ),
              ],
            ),
            child: child,
          );
        },
        child: Container(
          decoration: BoxDecoration(shape: BoxShape.circle, color: p.surface, image: panelImage),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 170 * k,
                  height: 170 * k,
                  child: CircularProgressIndicator(strokeWidth: 3 * k, color: glow),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                child: on
                    ? ShaderMask(
                        key: const ValueKey('on'),
                        shaderCallback: (r) => _brand.createShader(r),
                        child: Icon(Symbols.power_settings_new_rounded, size: 76 * k, color: Colors.white),
                      )
                    : Icon(
                        Symbols.power_settings_new_rounded,
                        key: const ValueKey('off'),
                        size: 76 * k,
                        color: p.accent,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Expressive»: a Material 3 Expressive scalloped shape. Off: a deep "cookie" in a tonal colour; connecting:
/// it spins; connected: it morphs into a softer shape filled with the accent and turns slowly.
class _ShapeButton extends StatefulWidget {
  final bool on, busy;
  final VoidCallback? onTap;
  final double scale;
  const _ShapeButton({required this.on, required this.busy, this.onTap, required this.scale});

  @override
  State<_ShapeButton> createState() => _ShapeButtonState();
}

class _ShapeButtonState extends State<_ShapeButton> with TickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 1))..addListener(_turn);
  late final _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    value: widget.on ? 1 : 0,
  );
  double _angle = 0;
  Duration? _last;

  void _turn() {
    // a free-running angle: the speed changes without a jump
    final now = _spin.lastElapsedDuration ?? Duration.zero;
    final dt = _last == null ? 0.0 : (now - _last!).inMicroseconds / 1e6;
    _last = now;
    final speed = widget.busy ? 3.2 : (widget.on ? .25 : 0.0); // rad / s
    _angle = (_angle + speed * dt) % (2 * pi);
  }

  void _sync() {
    if (widget.busy || widget.on) {
      if (!_spin.isAnimating) {
        _last = null;
        _spin.repeat();
      }
    } else {
      _spin.stop();
    }
    widget.on ? _morph.forward() : _morph.reverse();
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_ShapeButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _spin.dispose();
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = palette, k = widget.scale;
    return _Press(
      onTap: widget.onTap,
      child: SizedBox(
        width: 196 * k,
        height: 196 * k,
        child: AnimatedBuilder(
          animation: Listenable.merge([_spin, _morph]),
          builder: (context, _) {
            final m = Curves.easeInOutCubic.transform(_morph.value);
            final fill = Color.lerp(p.high, p.accent, m)!;
            final ink = Color.lerp(p.accent, p.onAccent, m)!;
            return Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.square(196 * k),
                  painter: _ScallopPainter(
                    color: fill,
                    lobes: 9,
                    depth: .085 - .05 * m, // deep cookie -> soft sunny shape
                    angle: _angle,
                    shadow: p.accent.withValues(alpha: .35 * m),
                  ),
                ),
                if (widget.busy)
                  SizedBox(
                    width: 120 * k,
                    height: 120 * k,
                    child: CircularProgressIndicator(strokeWidth: 3 * k, color: ink, strokeCap: StrokeCap.round),
                  ),
                Icon(Symbols.power_settings_new_rounded, size: 72 * k, color: ink),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ScallopPainter extends CustomPainter {
  final Color color, shadow;
  final int lobes;
  final double depth, angle;
  const _ScallopPainter({
    required this.color,
    required this.lobes,
    required this.depth,
    required this.angle,
    required this.shadow,
  });

  /// r(θ) = R · (1 − depth · (1 − cos(lobes·θ)) / 2): rounded lobes, smooth valleys.
  Path shape(Size size) {
    final c = size.center(Offset.zero);
    final rMax = size.shortestSide / 2 * .92;
    final path = Path();
    const steps = 360;
    for (var i = 0; i <= steps; i++) {
      final th = 2 * pi * i / steps;
      final r = rMax * (1 - depth * (1 - cos(lobes * th)) / 2);
      final o = c + Offset(cos(th + angle), sin(th + angle)) * r;
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape(size);
    if (shadow.a > 0) canvas.drawShadow(path, shadow, 14, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ScallopPainter o) =>
      o.color != color || o.depth != depth || o.angle != angle || o.lobes != lobes || o.shadow != shadow;
}

/// «Пилюля»: a wide button with the word on it, like a big Material 3 FAB.
class _PillButton extends StatelessWidget {
  final bool on, busy, stopping;
  final VoidCallback? onTap;
  final double scale;
  const _PillButton({required this.on, required this.busy, required this.stopping, this.onTap, required this.scale});

  @override
  Widget build(BuildContext context) {
    final p = palette, k = scale;
    final bg = on ? p.accent2 : p.accent;
    final fg = on
        ? (ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black)
        : p.onAccent;
    final label = busy ? (stopping ? 'Отключаю…' : 'Подключаю…') : (on ? 'Отключить' : 'Подключиться');
    return _Press(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        width: 272 * k,
        height: 80 * k,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(40 * k),
          boxShadow: [BoxShadow(color: bg.withValues(alpha: .35), blurRadius: 24 * k, offset: Offset(0, 8 * k))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 30 * k,
              height: 30 * k,
              child: busy
                  ? Padding(
                      padding: EdgeInsets.all(3 * k),
                      child: CircularProgressIndicator(strokeWidth: 3 * k, color: fg, strokeCap: StrokeCap.round),
                    )
                  : Icon(Symbols.power_settings_new_rounded, size: 30 * k, color: fg),
            ),
            SizedBox(width: 12 * k),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                label,
                key: ValueKey(label),
                style: TextStyle(fontSize: 20 * k, fontWeight: FontWeight.w800, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Свайп»: drag the knob to the other end to connect / back to disconnect (a tap on the knob works too).
class _SlideButton extends StatefulWidget {
  final bool on, busy, stopping;
  final VoidCallback? onTap;
  final double scale;
  const _SlideButton({required this.on, required this.busy, required this.stopping, this.onTap, required this.scale});

  @override
  State<_SlideButton> createState() => _SlideButtonState();
}

class _SlideButtonState extends State<_SlideButton> {
  double? _drag; // knob position 0..1 while dragging

  @override
  Widget build(BuildContext context) {
    final p = palette, k = widget.scale;
    // inside: 6 padding + 1.5 border on each side
    final w = 288 * k, h = 76 * k, knob = h - 15 * k, travel = w - knob - 15 * k;
    // the knob stays where the user left it while the VPN goes on / off
    final rest = (widget.busy ? !widget.stopping : widget.on) ? 1.0 : 0.0;
    final pos = _drag ?? rest;
    final color = Color.lerp(p.accent, p.accent2, widget.on ? 1 : pos)!;
    final hint = widget.busy
        ? (widget.stopping ? 'Отключаю…' : 'Подключаю…')
        : (widget.on ? '‹  Проведи влево' : 'Проведи вправо  ›');
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      label: widget.on ? 'Отключить' : 'Подключиться',
      onTap: widget.onTap,
      child: GestureDetector(
        onHorizontalDragUpdate: !enabled
            ? null
            : (d) => setState(() => _drag = ((_drag ?? rest) + d.delta.dx / travel).clamp(0.0, 1.0)),
        onHorizontalDragEnd: !enabled
            ? null
            : (_) {
                final crossed = rest == 1 ? (_drag ?? 1) < .3 : (_drag ?? 0) > .7;
                setState(() => _drag = null);
                if (crossed) widget.onTap!();
              },
        child: Container(
          width: w,
          height: h,
          padding: EdgeInsets.all(6 * k),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(h / 2),
            border: Border.all(color: color.withValues(alpha: .45), width: 1.5 * k),
          ),
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: EdgeInsets.only(left: rest == 1 ? 0 : knob, right: rest == 1 ? knob : 0),
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15 * k,
                      color: p.fg.withValues(alpha: .75 - .5 * (pos - rest).abs()),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: _drag == null ? const Duration(milliseconds: 300) : Duration.zero,
                curve: Curves.easeOutBack,
                left: pos * travel,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: widget.onTap,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: knob,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: color.withValues(alpha: .4), blurRadius: 14 * k)],
                    ),
                    child: widget.busy
                        ? Padding(
                            padding: EdgeInsets.all(18 * k),
                            child: CircularProgressIndicator(
                              strokeWidth: 3 * k,
                              color: p.onAccent,
                              strokeCap: StrokeCap.round,
                            ),
                          )
                        : Icon(
                            widget.on ? Symbols.check_rounded : Symbols.power_settings_new_rounded,
                            color: p.onAccent,
                            size: 30 * k,
                          ),
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
