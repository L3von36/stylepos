import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_log.dart';
import 'core/errors.dart';
import 'screens/splash_screen.dart';
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
import 'state/commissions.dart';
import 'state/products_view.dart';
import 'state/purchasing.dart';
import 'state/promotions.dart';
import 'state/sales.dart';
import 'state/sell_view.dart';
import 'state/settings.dart';
import 'widgets/ui.dart';

void main() {
  // Zone guard: anything that escapes async callbacks (a timer, a sync
  // microtask) lands here instead of killing the app. The till staying
  // alive matters more than any single failed task.
  runZonedGuarded(() async {
    await _bootstrap();
  }, (error, stack) {
    AppLog.e('zone/uncaught', error, stack);
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  installGlobalErrorHandlers();

  // Android-native chrome: draw behind the status bar and the gesture
  // navigation bar (edge-to-edge). The matching icon brightness is applied
  // per theme in [StylePosApp.build] — transparent bars over the app's own
  // surfaces is what makes the shell read as an app, not a browser page.
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: [],
  );
  SystemChrome.setSystemUIOverlayStyle(_overlayStyle(Brightness.light));

  final settings = AppSettings();
  final auth = AuthProvider();
  final catalog = CatalogProvider();
  final customers = CustomersProvider();
  final cart = CartProvider();
  final sales = SalesProvider();
  final nav = NavProvider();
  final attendance = AttendanceProvider();
  final purchasing = PurchasingProvider();
  final commissions = CommissionsProvider();
  final promotions = PromotionsProvider();
  final sellView = SellViewState();
  final productsView = ProductsViewState();

  // Load persisted settings + session before showing UI. Shell/UI state
  // (last tab, screen filters) restores in the same breath so the first
  // frame already shows where the shift left off.
  await Future.wait([
    settings.load(),
    auth.init(),
    ProductImages.init(),
    nav.restore(),
    sellView.restore(),
    productsView.restore(),
  ]);
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
      await purchasing.reloadAll(); // suppliers + POs arrive from the cloud
      await commissions.reload();
      await promotions.reload(); // coupons/campaigns from other devices
      sales.bump(); // reports + POS strip refresh with cloud sales
      attendance.bump(); // shift logs refresh when remote punches arrive
    };
    SyncService.I.start();
  } catch (e, s) {
    // No network / Supabase unreachable — the app stays fully offline.
    AppLog.w('cloud/init skipped', e, s);
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
    purchasing: purchasing,
    commissions: commissions,
    promotions: promotions,
    sellView: sellView,
    productsView: productsView,
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
  final PurchasingProvider purchasing;
  final CommissionsProvider commissions;
  final PromotionsProvider promotions;
  final SellViewState sellView;
  final ProductsViewState productsView;

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
    required this.purchasing,
    required this.commissions,
    required this.promotions,
    required this.sellView,
    required this.productsView,
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
        ChangeNotifierProvider<PurchasingProvider>.value(value: purchasing),
        ChangeNotifierProvider<CommissionsProvider>.value(value: commissions),
        ChangeNotifierProvider<PromotionsProvider>.value(value: promotions),
        ChangeNotifierProvider<SellViewState>.value(value: sellView),
        ChangeNotifierProvider<ProductsViewState>.value(value: productsView),
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
        final brightness =
            mode == ThemeMode.dark || (mode == ThemeMode.system && platformDark)
                ? Brightness.dark
                : Brightness.light;
        AppColors.brightness = brightness;
        // Keep the status-bar / nav-bar icon contrast in step with the
        // theme (transparent bars carry no colour of their own).
        SystemChrome.setSystemUIOverlayStyle(_overlayStyle(brightness));
        return MaterialApp(
          // Keyed by mode: a switch rebuilds the whole tree atomically
          // (static tokens + theme-dependent paints stay in step).
          key: ValueKey<ThemeMode>(mode),
          title: 'Sami',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          // ErrorToaster sits above the Navigator so every ErrorCenter
          // report surfaces as one consistent floating SnackBar, on every
          // screen, theme switches included.
          builder: (context, child) {
            Widget w = _ThemeSync(child: ErrorToaster(child: child!));
            // Touch platforms: kill the browser-style long-press
            // text-selection callouts/handles on labels. A till app never
            // wants to select "Subtotal" — the handles are the single
            // strongest "this is a web page" tell. Text fields keep their
            // own editing behaviour (unaffected by SelectionContainer).
            if (_touchPlatform) w = SelectionContainer.disabled(child: w);
            return w;
          },
          home: const SplashGate(),
        );
      }),
    );
  }
}

/// True where the primary pointer is a finger on a phone — Android and iOS
/// (web included: on the PWA the platform probe still reports the device).
/// Desktop keeps normal text selection for support/copy workflows.
final bool _touchPlatform = () {
  final p = defaultTargetPlatform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS;
}();

/// Transparent system bars with icons that stay legible on the app's own
/// surfaces — the edge-to-edge pair for the given brightness.
SystemUiOverlayStyle _overlayStyle(Brightness brightness) => SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness:
          brightness == Brightness.dark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness:
          brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    );

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
