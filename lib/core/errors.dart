import 'dart:io' show FileSystemException, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/ui.dart' show AppColors;
import 'app_log.dart';

/// Kinds of failures the app knows how to talk about.
enum AppErrorKind { network, storage, auth, validation, sync, unknown }

/// One place for "something failed". Carries a machine-readable [kind], a
/// short developer-facing [message] and the underlying [cause]. UI code
/// throws/catches these (or plain errors) and never formats messages by
/// hand — [friendlyError] owns the user-facing wording.
@immutable
class AppException implements Exception {
  final AppErrorKind kind;
  final String message;
  final Object? cause;

  const AppException(this.kind, this.message, [this.cause]);

  @override
  String toString() => 'AppException($kind, $message, cause: $cause)';
}

/// Maps any error to one plain sentence a shop owner can act on.
///
/// Unknown errors NEVER leak stack traces, driver names or HTTP codes to
/// the UI — the fallback is calm and true ("sales are saved") because the
/// app is offline-first: nothing a cashier does is lost by a failure here.
String friendlyError(Object error) {
  if (error is AppException) return error.message;
  final s = error.toString().toLowerCase();

  // Network / cloud
  if (error is SocketException ||
      s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('connection refused') ||
      s.contains('clientexception')) {
    return 'You seem offline — keep selling, everything syncs when the '
        'internet returns.';
  }
  if (s.contains('postgrest') || s.contains('supabase') || s.contains('graphql')) {
    if (s.contains('jwt') || s.contains('401') || s.contains('session')) {
      return 'Your session expired — sign in again to keep syncing.';
    }
    if (s.contains('row-level security') || s.contains('42501')) {
      return 'Your account is not allowed to change that from this device — '
          'ask the Manager.';
    }
    if (s.contains('duplicate') || s.contains('23505')) {
      return 'That item already exists in your shop.';
    }
    return 'The cloud shop could not be reached — your changes stay safe '
        'on this device and sync later.';
  }

  // Local storage
  if (error is FileSystemException || s.contains('filesystemexception')) {
    return 'Storage problem on this device — free up space, then try again.';
  }
  if (s.contains('no such table') || s.contains('sqlite') || s.contains('database')) {
    return 'Local storage hiccup — if it repeats, export a backup from '
        'Settings.';
  }
  if (s.contains('quotaexceeded') || s.contains('quota')) {
    return 'This device is out of space — remove a few product photos or '
        'old files.';
  }

  // Validation-style errors raised by the app itself
  if (error is ArgumentError || s.contains('invalid argument')) {
    return 'That value is not valid — check it and try again.';
  }

  return 'Something went wrong — your sales are saved. Try again.';
}

/// App-wide error sink.
///
/// Providers and screens report user-facing failures with [reportError]
/// instead of hand-rolling SnackBars; the root [ErrorToaster] displays
/// them in one consistent style. Singleton on purpose — one sink for the
/// whole app, usable from code without a BuildContext.
class ErrorCenter extends ChangeNotifier {
  ErrorCenter._();
  static final ErrorCenter I = ErrorCenter._();

  String? _last;
  int _seq = 0;

  /// Latest user-facing message (null until something was reported).
  String? get last => _last;

  /// Monotonic counter — advances on every report so listeners can tell
  /// "new error" from "same error reported again".
  int get seq => _seq;

  /// Shows [message] to the user as-is (already-friendly text).
  void report(String message) {
    _last = message;
    _seq++;
    notifyListeners();
  }

  /// Logs [error] under [where], then surfaces the mapped friendly text.
  void reportError(String where, Object error, [StackTrace? stack]) {
    AppLog.e(where, error, stack);
    report(friendlyError(error));
  }
}

/// Root listener that turns [ErrorCenter] reports into floating SnackBars
/// with the app's danger style. Mounted once inside MaterialApp.builder so
/// it sits above the Navigator and survives theme switches.
class ErrorToaster extends StatefulWidget {
  final Widget child;
  const ErrorToaster({super.key, required this.child});

  @override
  State<ErrorToaster> createState() => _ErrorToasterState();
}

class _ErrorToasterState extends State<ErrorToaster> {
  int _shownSeq = 0;

  @override
  void initState() {
    super.initState();
    ErrorCenter.I.addListener(_onReport);
    // Start from the current seq: pre-app reports (boot) are already
    // logged; only surface what happens while the UI is up.
    _shownSeq = ErrorCenter.I.seq;
  }

  @override
  void dispose() {
    ErrorCenter.I.removeListener(_onReport);
    super.dispose();
  }

  void _onReport() {
    final center = ErrorCenter.I;
    if (center.seq == _shownSeq || !mounted) return;
    _shownSeq = center.seq;
    final message = center.last;
    if (message == null) return;
    // Post-frame: showing a SnackBar mid-build/notification is illegal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 4),
        ));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Installs the app-wide safety nets. Call once from `main()`:
///
///  * framework build/layout errors -> log ring (default red screen in
///    debug only);
///  * uncaught platform/zone errors -> log ring, app stays alive;
///  * build-phase crash widgets -> a calm branded box instead of the grey
///    "RenderFlex overflowed" wall.
void installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    AppLog.e('flutter/${details.context?.name ?? 'framework'}',
        details.exception, details.stack);
    if (kDebugMode) FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.e('uncaught', error, stack);
    return true; // handled — keep the till alive no matter what
  };
  ErrorWidget.builder = (details) => _ErrorBox(details: details);
}

/// Branded replacement for Flutter's red/grey error widget. Deliberately
/// theme-free (explicit colors) — the error may BE a theme problem.
class _ErrorBox extends StatelessWidget {
  final FlutterErrorDetails details;
  const _ErrorBox({required this.details});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF6F7FB),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.build_circle_outlined,
              size: 40, color: Color(0xFF4F46E5)),
          const SizedBox(height: 12),
          const Text(
            'This part of the screen failed to load',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'The rest of the app keeps working — your sales are saved. '
            'Reopen this screen to retry.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Color(0xFF5B6474)),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  '${details.exception}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFFB3261E)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
