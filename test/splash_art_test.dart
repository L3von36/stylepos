import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:stylepos/screens/splash_screen.dart';

/// The splash animation must decode from the bundled asset. If
/// assets/lottie/splash.json were missing/corrupt, SplashView silently
/// falls back to a static badge — this test pins the real render.
void main() {
  testWidgets('SplashView plays the bundled Lottie (no fallback badge)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashView()));
    // Fixed pumps, NOT pumpAndSettle: the pulsing dots loop forever.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(LottieBuilder), findsOneWidget);
    expect(find.text('Sami'), findsOneWidget);
  });

  test('splash.json is a one-shot brand animation with the full cast', () {
    final doc =
        jsonDecode(File('assets/lottie/splash.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(doc['v'], isNotNull);
    expect(doc['fr'], 60, reason: 'same frame rate as sale_success.json');
    expect(doc['op'], 96, reason: '1.6s one-shot — never a looping progress');
    final layers = (doc['layers'] as List).cast<Map<String, dynamic>>();
    final names = layers.map((l) => l['nm']).toSet();
    expect(names, containsAll(<String>[
      'disc',
      'hanger',
      'hook',
      'halo',
    ]));
    expect(names.where((n) => (n as String).startsWith('c')).length,
        greaterThanOrEqualTo(7),
        reason: 'confetti burst layers present');
  });
}
