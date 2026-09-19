import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/scan_gate.dart';
import '../../widgets/ui.dart';

/// Full-screen camera scanner used at the counter to ring up items.
///
/// The gate inside guarantees that one physical scan resolves to exactly
/// one pop even though the camera keeps emitting detections while the
/// code is in frame. Returns the scanned string to the caller.
class ScanDialog extends StatefulWidget {
  const ScanDialog({super.key});

  @override
  State<ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<ScanDialog> {
  final ScanGate _gate = ScanGate();
  MobileScannerController? _controller;
  bool _done = false;
  String? _lastSeen;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code == null || code.trim().isEmpty) continue;
      if (!_gate.accept(code)) {
        // Same code still in frame -> ignore until cooldown elapses.
        if (mounted) setState(() => _lastSeen = code);
        continue;
      }
      _done = true;
      _lastSeen = code;
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop(code.trim());
      return;
    }
  }

  Future<void> _toggleTorch() async {
    final c = _controller;
    if (c == null) return;
    await c.toggleTorch();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan item barcode'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded),
            onPressed: _toggleTorch,
          ),
          const SizedBox(width: AppSpace.s1),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.s6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined,
                        size: 44, color: Colors.white70),
                    const SizedBox(height: AppSpace.s3),
                    Text(
                      'Camera unavailable.\nGrant Sami camera permission in system settings to scan barcodes.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: AppSpace.s4),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // scan window overlay
          IgnorePointer(
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              final boxW = w * 0.78;
              final boxH = (boxW * 0.62).clamp(150.0, 240.0);
              return CustomPaint(
                size: Size(c.maxWidth, c.maxHeight),
                painter: _ReticlePainter(
                  rect: Rect.fromCenter(
                    center: Offset(w / 2, c.maxHeight * 0.42),
                    width: boxW,
                    height: boxH,
                  ),
                ),
              );
            }),
          ),
          // bottom hints
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + AppSpace.s6,
            child: Column(
              children: [
                Text(
                  _lastSeen == null
                      ? 'Point the camera at the barcode on the garment tag'
                      : 'Scanned $_lastSeen',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AppSpace.s1),
                const Text(
                  'One scan adds one item. Scan again after a moment to repeat.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dark scrim with a bright rounded scan window and corner ticks.
// (Painted manually so the reticle works on every supported version.)
class _ReticlePainter extends CustomPainter {
  final Rect rect;
  _ReticlePainter({required this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = const Color(0x87000000);
    final rrect = RRect.fromRectAndRadius(
        rect.inflate(10), const Radius.circular(20));
    // Cut a hole for the scan window.
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, scrim);

    final tick = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 26.0;
    final corners = [
      (rect.topLeft, Offset(1, 0), Offset(0, 1)),
      (rect.topRight, Offset(-1, 0), Offset(0, 1)),
      (rect.bottomLeft, Offset(1, 0), Offset(0, -1)),
      (rect.bottomRight, Offset(-1, 0), Offset(0, -1)),
    ];
    for (final (corner, dx, dy) in corners) {
      canvas.drawLine(corner, corner + dx * len, tick);
      canvas.drawLine(corner, corner + dy * len, tick);
    }
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter oldDelegate) => oldDelegate.rect != rect;
}

/// Convenience helper so callers can open the scanner with one line.
Future<String?> openScanner(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const ScanDialog()),
  );
}
