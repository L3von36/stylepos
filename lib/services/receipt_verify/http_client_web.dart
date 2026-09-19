import 'package:http/http.dart' as http;

/// Web implementation: browsers enforce certificate validity themselves, so
/// the flag is ignored (the verifier surfaces CORS guidance instead).
http.Client createVerifyClient({bool allowBadCert = false}) => http.Client();
