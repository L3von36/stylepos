import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// IO implementation: for banks with broken TLS certificates (Awash's :8225
/// endpoint, CBE) we build a dedicated client that tolerates the bad
/// certificate — only that per-request client, never the app at large.
http.Client createVerifyClient({bool allowBadCert = false}) {
  if (!allowBadCert) return http.Client();
  final inner = HttpClient()..badCertificateCallback = (cert, host, port) => true;
  return IOClient(inner);
}
