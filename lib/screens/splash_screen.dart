import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart' as lottie_pkg;
import 'package:provider/provider.dart';

import '../state/auth.dart';
import '../widgets/ui.dart';
import 'home_shell.dart';
import 'login_screen.dart';

/// How long the brand splash stays on screen at minimum. Covers the 1.6s
/// Lottie plus a short hold; slower devices keep the splash (with its
/// pulsing dots) until [AuthProvider.ready] flips — the splash never
/// becomes a spinner, it just waits a beat longer.
const _minSplash = Duration(milliseconds: 1900);

/// Entry gate: plays the branded splash (Lottie + wordmark) on every
/// launch, then cross-fades into the login screen or the till. Replaces
/// the old bare CircularProgressIndicator loading root — the first thing
/// a shop owner sees should be the brand, in light mode, on every device
/// regardless of the OS/app theme setting.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _minTimeDone = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(_minSplash, () {
      if (mounted) setState(() => _minTimeDone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ready = _minTimeDone && auth.ready;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // Keyed by destination so the splash fades out once, cleanly.
      child: ready
          ? KeyedSubtree(
              key: const ValueKey('app'),
              child: auth.user == null ? const LoginScreen() : const HomeShell(),
            )
          : const SplashView(key: ValueKey('splash')),
    );
  }
}

/// The splash itself: always light (a brand moment, never a dark surface),
/// indigo hanger animation on white, wordmark + tagline, pulsing dots at
/// the bottom while the app finishes booting. Colors are fixed light-mode
/// values on purpose — dark mode starts one tap later, after the fade.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.white,
        systemNavigationBarColor: Colors.white,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _SplashArt(size: 168),
                      const SizedBox(height: AppSpace.s6),
                      const Text(
                        'Sami',
                        style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: AppSpace.s2),
                      const Text(
                        'Point of sale for clothing shops',
                        style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 14,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const _PulsingDots(),
              const SizedBox(height: AppSpace.s8),
            ],
          ),
        ),
      ),
    );
  }
}

/// The boot animation: indigo rounded-square pops in (echoing the launcher
/// icon), the white hanger draws itself, confetti pops and settles. Plays
/// once — never loops — so the splash can't read as an endless progress.
/// If the asset fails to decode, the static brand badge stays (the till
/// must never be blocked by a decorative animation).
class _SplashArt extends StatelessWidget {
  final double size;

  const _SplashArt({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: lottie_pkg.Lottie.asset(
        'assets/lottie/splash.json',
        width: size,
        height: size,
        fit: BoxFit.contain,
        repeat: false,
        animate: true,
        errorBuilder: (context, error, stack) => Container(
          width: size * 0.62,
          height: size * 0.62,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: const Icon(Icons.checkroom_rounded,
              color: Colors.white, size: 44),
        ),
      ),
    );
  }
}

/// Three indigo dots pulsing in a staggered wave — a calm "still working"
/// cue for devices where boot (or first sync) takes longer than the
/// brand moment. Loops only while the splash is up.
class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Smooth sine pulse, phase-shifted per dot (1 = fully lit, 0 = dimmed).
  double _pulse(double t, double phase) =>
      (1 - math.cos(2 * math.pi * ((t - phase) % 1.0))) / 2;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final phase in const [0.0, 0.18, 0.36])
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 5),
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: const Color(0xFF4F46E5)
                      .withValues(alpha: 0.25 + 0.65 * _pulse(_c.value, phase)),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        );
      },
    );
  }
}
