import 'package:flutter/material.dart';
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

/// Checkout success: the liquid download filling to 100% and popping the
/// green check — the sale went through. The artboard's own white background
/// is presented as a deliberate white circle tile on the green panel.
class SaleSuccessArt extends StatelessWidget {
  const SaleSuccessArt({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(6),
      child: RiveView(
        asset: 'assets/rive/liquid_download.riv',
        size: size,
        fallback: Icon(Icons.check_rounded, size: 30, color: AppColors.success),
      ),
    );
  }
}
