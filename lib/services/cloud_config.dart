/// Supabase project credentials for Sami cloud sync.
///
/// The anon key is a *publishable* key: it is safe to embed in the app.
/// Data protection comes from Row Level Security (no login = no data),
/// not from keeping this key secret.
class CloudConfig {
  static const String url = 'https://jagbhazhbbiwqahkjusg.supabase.co';
  static const String publishableKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImphZ2JoYXpoYmJpd3FhaGtqdXNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2NTk3OTMsImV4cCI6MjEwNTIzNTc5M30.Y6zSciS_2x3G358y8SG4uL2hXEkcm3RQnsnmw7RC0Uc';
}
