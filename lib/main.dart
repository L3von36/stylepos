import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'state/auth.dart';
import 'state/cart.dart';
import 'state/catalog.dart';
import 'state/customers.dart';
import 'state/nav.dart';
import 'state/sales.dart';
import 'state/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = AppSettings();
  final auth = AuthProvider();
  final catalog = CatalogProvider();
  final customers = CustomersProvider();
  final cart = CartProvider();
  final sales = SalesProvider();
  final nav = NavProvider();

  // Load persisted settings + session before showing UI.
  await Future.wait([settings.load(), auth.init()]);
  // First-run bootstrapping of the starter catalog.
  await catalog.reload();
  await customers.reload();

  runApp(StylePosApp(
    settings: settings,
    auth: auth,
    catalog: catalog,
    customers: customers,
    cart: cart,
    sales: sales,
    nav: nav,
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

  const StylePosApp({
    super.key,
    required this.settings,
    required this.auth,
    required this.catalog,
    required this.customers,
    required this.cart,
    required this.sales,
    required this.nav,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<CatalogProvider>.value(value: catalog),
        ChangeNotifierProvider<CustomersProvider>.value(value: customers),
        ChangeNotifierProvider<CartProvider>.value(value: cart),
        ChangeNotifierProvider<SalesProvider>.value(value: sales),
        ChangeNotifierProvider<NavProvider>.value(value: nav),
      ],
      child: MaterialApp(
        title: 'StylePOS',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        home: const _Root(),
      ),
    );
  }

  ThemeData _buildTheme() {
    const seed = Color(0xFF3F51B5); // indigo
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF5F6FA),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: Colors.grey.shade300),
      ),
    );
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
