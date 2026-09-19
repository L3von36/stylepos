import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart' as lottie_pkg;
import 'package:rive/rive.dart' as rive;

import 'ui.dart';

/// A graceful host for a bundled Rive animation.
///
/// The .riv file is decoded once up-front: if Rive can play it we render
/// [RiveAnimation.asset] (default playback: first animation, looping), and if
/// anything fails — missing asset, corrupt file, unsupported runtime — the
/// static [fallback] is shown instead. The till must never break because of
/// a decorative animation.
class RiveView extends StatefulWidget {
  final String asset;
  final double size;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? fallback;

  const RiveView({
    super.key,
    required this.asset,
    this.size = 120,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.fallback,
  });

  @override
  State<RiveView> createState() => _RiveViewState();
}

class _RiveViewState extends State<RiveView> {
  late final Future<bool> _decodes;

  @override
  void initState() {
    super.initState();
    _decodes = _verify();
  }

  Future<bool> _verify() async {
    try {
      final file = await rive.RiveFile.asset(widget.asset);
      return file.artboards.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _decodes,
      builder: (context, snap) {
        // Always hard-bound the animation box: Rive's render object expands
        // to whatever constraints it is given, which would blow up layouts
        // that expect a fixed-size art (e.g. inside a Row).
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: snap.data == true
              ? rive.RiveAnimation.asset(
                  widget.asset,
                  fit: widget.fit,
                  alignment: widget.alignment,
                )
              : widget.fallback,
        );
      },
    );
  }
}

/// Empty-cart hero: the off-road buggy bouncing along — playful "next
/// delivery incoming" vignette, framed as a rounded illustration card so
/// the artboard's own scene background reads as intentional art.
class EmptyCartArt extends StatelessWidget {
  const EmptyCartArt({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.borderSoft),
        boxShadow: [
          BoxShadow(
              color: AppColors.isDark ? const Color(0x40000000) : const Color(0x140F172A),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg - 1),
        child: RiveView(
          asset: 'assets/rive/off_road_car.riv',
          size: 150,
          fallback: Container(
            color: AppColors.surfaceTint,
            child: Icon(Icons.local_shipping_outlined,
                size: 40, color: AppColors.faint),
          ),
        ),
      ),
    );
  }
}

/// Checkout success: a one-shot Lottie — the green disc pops in, the ring
/// and the white check draw themselves, confetti pops, everything settles.
/// Plays once (never loops) so the done screen never reads as a still-spinning
/// progress. If the asset fails to load the static check stays.
class SaleSuccessArt extends StatelessWidget {
  const SaleSuccessArt({super.key, this.size = 80});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: lottie_pkg.Lottie.asset(
        'assets/lottie/sale_success.json',
        width: size,
        height: size,
        fit: BoxFit.contain,
        repeat: false,
        animate: true,
        errorBuilder: (context, error, stack) =>
            Icon(Icons.check_circle_rounded, size: size, color: AppColors.success),
      ),
    );
  }
}
