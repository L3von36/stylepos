import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:stylepos/widgets/rive_view.dart';

/// The checkout success animation must decode from the bundled asset.
/// If assets/lottie/sale_success.json were missing/corrupt, SaleSuccessArt
/// silently falls back to a static icon — this test pins the real render.
void main() {
  testWidgets('SaleSuccessArt plays the bundled Lottie (no fallback icon)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: SaleSuccessArt(size: 80))),
    ));
    // Let the asset load + the 96-frame animation run to completion
    // (1.6s at 60fps; repeat:false so frames stop being scheduled).
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byType(LottieBuilder), findsOneWidget);
  });
}
