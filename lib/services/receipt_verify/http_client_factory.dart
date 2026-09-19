/// Picks the HTTP client factory for the current platform
/// (IO gets bad-certificate tolerance for Awash/CBE, web uses plain http).
library;

export 'http_client_io.dart' if (dart.library.js_interop) 'http_client_web.dart';
