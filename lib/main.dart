import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/cloud_auth.dart';
import 'services/cloud_config.dart';
import 'services/images.dart';
import 'services/sync_service.dart';
import 'state/auth.dart';
import 'state/attendance.dart';
import 'state/cart.dart';
import 'state/catalog.dart';
import 'state/customers.dart';
import 'state/nav.dart';
import 'state/sales.dart';
import 'state/settings.dart';
import 'widgets/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = AppSettings();
  final auth = AuthProvider();
  final catalog = CatalogProvider();
  final customers = CustomersProvider();
  final cart = CartProvider();
  final sales = SalesProvider();
  final nav = NavProvider();
  final attendance = AttendanceProvider();

  // Load persisted settings + session before showing UI.
  await Future.wait([settings.load(), auth.init(), ProductImages.init()]);
  // First-run bootstrapping of the starter catalog.
  await catalog.reload();
  await customers.reload();
  // Restore any sales parked (held) before the app last closed.
  await cart.loadHeld();

  // Cloud sync (Supabase): offline-safe — failing to reach the cloud
  // must never stop the POS, so init is best-effort.
  try {
    await Supabase.initialize(
        url: CloudConfig.url, publishableKey: CloudConfig.publishableKey);
    CloudAuth.auth = auth; // landing-screen cloud sign-in maps to local staff
    SyncService.I.onSynced = () async {
      await settings.load(); // shop settings refresh after wipes/pulls
      await catalog.reload();
      await customers.reload();
      sales.bump(); // reports + POS strip refresh with cloud sales
    };
    SyncService.I.start();
  } catch (_) {
    // No network / Supabase unreachable — the app stays fully offline.
  }

  runApp(StylePosApp(
    settings: settings,
    auth: auth,
    catalog: catalog,
    customers: customers,
    cart: cart,
    sales: sales,
    nav: nav,
    attendance: attendance,
  ));
}

class StylePosApp extends StatelessWidget {
  final AppSettings settings;
  final AuthProvider auth;
  final CatalogProvider catalog;
  final CustomersProvider customers;
  final CartProvider cart;
  final SalesProvider sales;
  final NavProvider nav;
  final AttendanceProvider attendance;

  const StylePosApp({
    super.key,
    required this.settings,
    required this.auth,
    required this.catalog,
    required this.customers,
    required this.cart,
    required this.sales,
    required this.nav,
    required this.attendance,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<CatalogProvider>.value(value: catalog),
        ChangeNotifierProvider<CustomersProvider>.value(value: customers),
        ChangeNotifierProvider<CartProvider>.value(value: cart),
        ChangeNotifierProvider<SalesProvider>.value(value: sales),
        ChangeNotifierProvider<NavProvider>.value(value: nav),
        ChangeNotifierProvider<AttendanceProvider>.value(value: attendance),
      ],
      child: Builder(builder: (context) {
        // Watch settings so a System/Light/Dark switch rebuilds MaterialApp.
        final mode = context.watch<AppSettings>().themeMode;
        // Resolve the effective brightness BEFORE building the themes — the
        // ThemeData factories read AppColors statics, which must already
        // reflect the new mode (the in-app _ThemeSync runs too late for
        // theme construction).
        final platformDark = WidgetsBinding
                .instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
        AppColors.brightness =
            mode == ThemeMode.dark || (mode == ThemeMode.system && platformDark)
                ? Brightness.dark
                : Brightness.light;
        return MaterialApp(
          // Keyed by mode: a switch rebuilds the whole tree atomically
          // (static tokens + theme-dependent paints stay in step).
          key: ValueKey<ThemeMode>(mode),
          title: 'Sami',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          builder: (context, child) => _ThemeSync(child: child!),
          home: const _Root(),
        );
      }),
    );
  }
}

/// Keeps the static [AppColors] token table in step with the effective
/// Material theme, so brightness-aware getters resolve correctly the moment
/// the user switches System / Light / Dark.
class _ThemeSync extends StatelessWidget {
  final Widget child;
  const _ThemeSync({required this.child});

  @override
  Widget build(BuildContext context) {
    AppColors.brightness = Theme.of(context).brightness;
    return child;
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return auth.user == null ? const LoginScreen() : const HomeShell();
  }
}
