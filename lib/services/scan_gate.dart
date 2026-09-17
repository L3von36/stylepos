/// Guards the POS against double-scans.
///
/// Camera scanners fire several detections per second while a code is in
/// frame, and some USB/Bluetooth scanners resend the code right after the
/// Enter suffix. The classic symptom the shop reported is one physical
/// scan adding two or three items to the cart.
///
/// The gate accepts a code only when it differs from the previously
/// accepted one, or when the cooldown window has elapsed since that code
/// was last accepted. Deliberately selling a second identical item still
/// works: scan again after the cooldown (or tap the + stepper in the cart).
class ScanGate {
  final Duration cooldown;
  String? _last;
  DateTime? _lastAt;
  int rejected = 0;

  ScanGate({this.cooldown = const Duration(milliseconds: 1600)});

  /// True when this code should be processed now.
  bool accept(String code) {
    final c = code.trim();
    if (c.isEmpty) return false;
    final now = DateTime.now();
    final isDuplicate = _last == c &&
        _lastAt != null &&
        now.difference(_lastAt!) < cooldown;
    _last = c;
    _lastAt = now;
    if (isDuplicate) {
      rejected++;
      return false;
    }
    return true;
  }

  /// Forgets history (e.g. when the dialog reopens).
  void reset() {
    _last = null;
    _lastAt = null;
  }
}
