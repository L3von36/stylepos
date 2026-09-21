import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/sync_service.dart';

/// Pins the v1.24.0 quota-guard cadence (keep-alive safety net of the
/// sync engine). The contract the shop's Supabase quota depends on:
/// with zero changes the idle device syncs at most every ~15 minutes
/// while realtime is live (everything else arrives as realtime events),
/// catches up every ~3 minutes while the channel is down, and retries a
/// failed cycle quickly so stuck rows never wait long.
void main() {
  group('sync keep-alive quota guard (tick = 45s each)', () {
    test('failed cycle retries within ~90s (even-tick cadence)', () {
      // The failed cycle itself was started by run(); retries fire on
      // every second tick -> a stuck row waits at most ~90s. The error
      // cadence is strictly the even-tick rule regardless of channel state.
      expect(shouldKeepAliveSync(tick: 2, hasError: true, realtimeLive: false),
          isTrue);
      expect(shouldKeepAliveSync(tick: 4, hasError: true, realtimeLive: true),
          isTrue);
      expect(shouldKeepAliveSync(tick: 3, hasError: true, realtimeLive: false),
          isFalse);
      expect(shouldKeepAliveSync(tick: 1, hasError: true, realtimeLive: false),
          isFalse);
    });

    test('realtime LIVE: at most one verify per 20 ticks (~15 min)', () {
      for (var tick = 1; tick <= 40; tick++) {
        final maySync = shouldKeepAliveSync(
            tick: tick, hasError: false, realtimeLive: true);
        expect(maySync, tick % 20 == 0,
            reason: 'tick $tick must ${tick % 20 == 0 ? '' : 'not '}sync');
      }
    });

    test('channel DOWN: catch-up pull every 4 ticks (~3 min)', () {
      for (var tick = 1; tick <= 12; tick++) {
        final maySync = shouldKeepAliveSync(
            tick: tick, hasError: false, realtimeLive: false);
        expect(maySync, tick % 4 == 0,
            reason: 'tick $tick must ${tick % 4 == 0 ? '' : 'not '}sync');
      }
    });

    test('quota math: a quiet, live shop idles at 96 syncs/day per device '
        '(the old engine did 1,920 full cycles/day even doing nothing)', () {
      var syncs = 0;
      for (var tick = 1; tick <= 1920; tick++) {
        if (shouldKeepAliveSync(
            tick: tick, hasError: false, realtimeLive: true)) {
          syncs++;
        }
      }
      expect(syncs, 96);
    });
  });
}
