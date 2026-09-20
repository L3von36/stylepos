import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'customers/customers_screen.dart';
import 'pos/pos_screen.dart';
import 'products/products_screen.dart';
import 'purchasing/purchasing_screen.dart';
import 'reports/reports_screen.dart';
import 'sales/sales_screen.dart';
import 'settings/settings_screen.dart';
import 'settings/users_screen.dart';
import '../data/database.dart';
import '../models/user.dart';
import '../services/cloud_auth.dart';
import '../services/sync_service.dart';
import '../state/auth.dart';
import '../state/catalog.dart';
import '../state/nav.dart';
import '../state/settings.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/backup_reminder.dart';
import '../widgets/ui.dart';
import 'sync_status_pill.dart';
import 'verify/receipt_verifier_screen.dart';
import '../state/cart.dart';

/// Phone bottom bar composition: exactly FOUR primary tabs + "More".
///
/// The bar's hard ceiling stays SIX destination cells + More (seven taps
/// total) so it can never crowd the till — but the shipped configuration is
/// four. Anything beyond the four primaries (Purchasing, Reports today;
/// anything added tomorrow) automatically lands inside the More sheet
/// because the shell splits the destination list at [kBarTabs]. NEVER add
/// new menus to the bar directly — append them to the list and let the
/// split do the work.
const int kBarTabs = 4;

class _Dest {
  final NavId id;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final Widget page;
  const _Dest(this.id, this.icon, this.activeIcon, this.label, this.page);
}

/// One slot in the phone bottom bar. [isMore] marks the trailing "More"
/// entry — it opens the account sheet instead of switching pages and is
/// never shown as selected.
class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isMore;
  const _NavItem(this.icon, this.activeIcon, this.label, {this.isMore = false});
}

/// Adaptive app scaffold: NavigationRail on wide screens (desktop/tablet),
/// and a compact custom bottom bar on phones — icon + label cells plus a
/// trailing "More" slot, small enough to stay out of the till's way.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool _gatesDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runPostLoginGates());
  }

  /// Runs once per session, after the first frame: (1) the legacy-data
  /// gate — old pre-cloud data on this device while a cloud shop is
  /// active; (2) the one-time "create staff accounts" hint for Managers.
  Future<void> _runPostLoginGates() async {
    if (_gatesDone || !mounted) return;
    _gatesDone = true;

    final authP = context.read<AuthProvider>();
    final user = authP.user;
    if (user == null) return;

    // ---- gate 1: old local data vs the cloud shop -------------------
    try {
      final legacy = await CloudAuth.legacyDataInfo();
      if (legacy != null && mounted) {
        final upload = await _showLegacyDataDialog(legacy);
        await CloudAuth.resolveLegacyData(upload: upload);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(upload
              ? 'Keeping local data — it will join your shop on the next sync.'
              : 'Fresh start! Pulling your shop data from the cloud…'),
        ));
        await SyncService.I.run();
      }
    } catch (_) {// Never block the till on the gate.
    }

    // ---- gate 3: keep the local shop name in step with the cloud shop ---
    // Signing up on one device used to leave the app bar / receipts saying
    // the factory name ("My Clothing Shop") forever. Heal devices that
    // still carry the untouched default; a manager-customized receipt name
    // in Settings is never overwritten.
    try {
      final cloud = await CloudAuth.fetchMyShop();
      final cloudName = cloud?['name'] ?? '';
      if (cloudName.isNotEmpty && mounted) {
        final sp = context.read<AppSettings>();
        if (sp.shopName == AppSettings.defaultShopName) {
          await sp.save(shopName: cloudName);
        }
      }
    } catch (_) {// Cosmetic heal — never block the till.
    }

    // ---- gate 2: first-run staff hint (managers) ---------------------
    if (!mounted || !user.isAdmin) return;
    try {
      final db = await DB.instance();
      final flag = await db.query('settings',
          where: 'key = ?', whereArgs: ['staff_prompt_done']);
      final done = flag.isNotEmpty && flag.first['value'] == '1';
      if (done) return;
      final users = await authP.listUsers();
      if (users.length <= 1 && mounted) {
        await _showStaffPrompt();
      }
      await db.insert('settings', {'key': 'staff_prompt_done', 'value': '1'});
    } catch (_) {
    }
  }

  Future<bool> _showLegacyDataDialog(LegacyDataInfo legacy) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Old data on this device'),
              content: SizedBox(
                // Message dialogs wrap at a fixed reading width instead of
                // stretching edge-to-edge on desktop (matches the other
                // confirm dialogs' width family).
                width: 400,
                child: Text(
                  'This device has data that is not part of your cloud '
                  'shop:\n\n'
                  '• ${legacy.sales} old sale${legacy.sales == 1 ? '' : 's'}\n'
                  '• ${legacy.unsyncedProducts} product${legacy.unsyncedProducts == 1 ? '' : 's'} '
                  'never synced\n\n'
                  'Start fresh to see ONLY your shop\'s shared data on this '
                  'device (recommended), or upload the old data to your shop.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Upload to my shop'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                  ),
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Start fresh (recommended)'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _showStaffPrompt() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add your staff'),
        content: const SizedBox(
          // Fixed reading width — same family as the other message dialogs.
          width: 400,
          child: Text(
            'Create cloud accounts for your cashiers — they sign in on any '
            'device (Staff tab) with the email + password you set, and every '
            'sale they make lands in your shared shop data.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const UsersScreen()));
            },
            icon: const Icon(Icons.person_add_alt_rounded, size: 18),
            label: const Text('Add staff'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<AppSettings>();
    final nav = context.watch<NavProvider>();
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();

    final all = [
      _Dest(NavId.pos, Icons.point_of_sale_outlined, Icons.point_of_sale_rounded, 'Sell',
          const PosScreen()),
      _Dest(NavId.products, Icons.inventory_2_outlined, Icons.inventory_2_rounded, 'Products',
          const ProductsScreen()),
      _Dest(NavId.sales, Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Sales',
          const SalesScreen()),
      _Dest(NavId.customers, Icons.people_outline, Icons.people_alt_rounded, 'Customers',
          const CustomersScreen()),
      if (user.isAdmin)
        _Dest(NavId.purchasing, Icons.local_shipping_outlined,
            Icons.local_shipping_rounded, 'Purchasing', const PurchasingScreen()),
      if (user.isAdmin)
        _Dest(NavId.reports, Icons.insights_outlined, Icons.insights_rounded, 'Reports',
            const ReportsScreen()),
    ];
    final index = all.indexWhere((d) => d.id == nav.id).clamp(0, all.length - 1);

    // Low-stock alert badge on the Products destination (sidebar pill and
    // phone bottom-bar badge). Catalog updates (sales, adjustments, sync)
    // re-notify, so the count stays live.
    final lowCount = context.watch<CatalogProvider>().lowStockItems().length;
    int? productsBadge(int i) =>
        (all[i].id == NavId.products && lowCount > 0) ? lowCount : null;

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final appBar = _buildAppBar(context, user: user, settings: settings, desktop: wide);

      if (wide) {
        final extended = constraints.maxWidth >= 1240;
        // Desktop layout: full-height design-system sidebar + the app bar
        // spanning only the content area (standard desktop app anatomy).
        // The backup nudge stays on the Sell tab only — an amber strip
        // above every screen reads as an error, not a reminder.
        return Scaffold(
          body: Row(
            children: [
              AppSidebar(
                extended: extended,
                onVerify: () => _openVerifier(context),
                destinations: [
                  for (var i = 0; i < all.length; i++)
                    SidebarDest(
                      icon: all[i].icon,
                      activeIcon: all[i].activeIcon,
                      label: all[i].label,
                      badge: productsBadge(i),
                    ),
                ],
                selectedIndex: index,
                onSelect: (i) {
                  // Defer the unfocus + tab switch to after the current
                  // pointer/gesture dispatch. Mutating focus or notifying
                  // providers mid-tap fouls the input stream on web — the
                  // next taps (including on the sidebar itself) land on a
                  // stale hit-test and feel dead (same class of bug as the
                  // checkout quick-cash chips).
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    FocusManager.instance.primaryFocus?.unfocus();
                    nav.goTo(all[i].id);
                  });
                },
                user: user,
                onSettings: user.isAdmin
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsScreen()))
                    : null,
                onStaff: user.isAdmin
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const UsersScreen()))
                    : null,
                onChangePassword: () => _showChangePassword(context),
                onSignOut: () => _confirmSignOut(context),
              ),
              VerticalDivider(width: 1, thickness: 1, color: AppColors.borderSoft),
              Expanded(
                child: Scaffold(
                  appBar: appBar,
                  body: Column(
                    children: [
                      if (nav.id == NavId.pos)
                        BackupReminderBanner.maybe(
                          context,
                          onBackup: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SettingsScreen())),
                        ) ?? const SizedBox.shrink(),
                      Expanded(
                        child: IndexedStack(
                            index: index,
                            children: [for (final d in all) d.page]),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }

      // Phone layout: content + compact bottom bar. The trailing "More"
      // slot opens the account sheet, which now doubles as the overflow
      // menu: every destination past the four primary tabs (Purchasing,
      // Reports today) is listed there, plus the account tools.
      //
      // Shipped composition: FOUR primary tabs + More (see kBarTabs). The
      // bar's absolute ceiling remains six cells + More — never exceeded,
      // new menus go inside the More sheet, never the bar itself.
      final barDestinations = all.take(kBarTabs).toList();
      final moreDestinations = all.skip(kBarTabs).toList();
      final moreActive =
          barDestinations.indexWhere((d) => d.id == nav.id) == -1;
      return Scaffold(
        appBar: appBar,
        body: Column(
          children: [
            if (nav.id == NavId.pos)
              BackupReminderBanner.maybe(
                context,
                onBackup: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ) ?? const SizedBox.shrink(),
            Expanded(
              child: IndexedStack(
                  index: index, children: [for (final d in all) d.page]),
            ),
          ],
        ),
        bottomNavigationBar: _PhoneNavBar(
          items: [
            for (final d in barDestinations)
              _NavItem(d.icon, d.activeIcon, d.label),
            const _NavItem(Icons.more_horiz_rounded, Icons.more_horiz_rounded,
                'More', isMore: true),
          ],
          selectedIndex: barDestinations.indexWhere((d) => d.id == nav.id),
          moreActive: moreActive,
          lowStock: lowCount,
          lowStockIndex:
              barDestinations.indexWhere((d) => d.id == NavId.products),
          onSelect: (i) {
            // Defer the unfocus + tab switch to after the current pointer
            // dispatch (see the sidebar onSelect comment). Unfocusing or
            // notifying during the tap is what made the bar feel dead:
            // with the POS search keyboard open, the IME dismiss rebuilt
            // the tree mid-gesture and the NEXT destination taps were
            // swallowed until an unrelated relayout unstuck them.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              FocusManager.instance.primaryFocus?.unfocus();
              nav.goTo(barDestinations[i].id);
            });
          },
          onMore: () => _showAccountSheet(context, user, moreDestinations),
        ),
      );
    });
  }

  /// Opens the receipt verifier as a pushed task screen. [expectedAmount]
  /// prefills the "amount they should have paid" comparison field (the open
  /// cart total when launched from the till).
  void _openVerifier(BuildContext context, {double? expectedAmount}) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptVerifierScreen(
            initialExpectedAmount: expectedAmount)));
  }

  /// The app bar. On desktop it spans only the content column — identity,
  /// settings and sign-out live in the sidebar, so it stays minimal
  /// (shop name + sync pill). Phones keep it equally quiet: sync pill + a
  /// one-tap Sign out in the top-right corner (the old gear was redundant —
  /// Settings still lives in the More sheet), so ending a shift never
  /// requires digging through menus.
  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required AppUser user,
    required AppSettings settings,
    required bool desktop,
  }) {
    final nav = context.read<NavProvider>();
    final appBar = AppBar(
      title: desktop
          ? Text(settings.shopName, overflow: TextOverflow.ellipsis)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: AppColors.brandGradient,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(Icons.storefront_rounded, size: 17, color: Colors.white),
                ),
                const SizedBox(width: AppSpace.s2 + 2),
                Flexible(child: Text(settings.shopName, overflow: TextOverflow.ellipsis)),
              ],
            ),
      actions: [
        // Till-side receipt verification: one tap from wherever the cashier
        // already is. On the Sell tab it prefills the open cart total so the
        // "did they pay enough?" comparison is zero-effort.
        IconButton(
          tooltip: 'Verify receipt',
          icon: const Icon(Icons.verified_user_outlined, size: 20),
          onPressed: () {
            double? expected;
            if (nav.id == NavId.pos) {
              final cart = context.read<CartProvider>();
              if (cart.subtotal > 0) expected = cart.total(settings.taxRate);
            }
            _openVerifier(context, expectedAmount: expected);
          },
        ),
        const SyncStatusPill(),
        if (!desktop)
          IconButton(
            tooltip: 'Sign out',
            icon: Icon(Icons.logout_rounded, size: 21, color: AppColors.danger),
            onPressed: () => _confirmSignOut(context),
          ),
        const SizedBox(width: AppSpace.s1),
      ],
    );
    return appBar;
  }

  /// Compact account sheet for phones: who is signed in, the overflow
  /// destinations that didn't fit the four primary tabs ([moreDests] —
  /// Purchasing and Reports today, anything added tomorrow), then the
  /// account tools (password, sign out).
  void _showAccountSheet(
      BuildContext context, AppUser user, List<_Dest> moreDests) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.s5, AppSpace.s5, AppSpace.s5, AppSpace.s3),
              child: Row(
                children: [
                  InitialsAvatar(user.name, size: 42),
                  const SizedBox(width: AppSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            style: TextStyle(
                                fontFamily: 'Carlito', fontSize: 15,
                                fontWeight: FontWeight.w700, color: AppColors.ink)),
                        Text(
                          '${user.isAdmin ? 'Manager' : 'Sales'} · ${user.email}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            if (moreDests.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.s5, AppSpace.s1, AppSpace.s5, AppSpace.s1),
                child: Text('MENU',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: AppColors.muted)),
              ),
              for (final d in moreDests)
                ListTile(
                  leading: Icon(d.icon, color: AppColors.muted),
                  title: Text(d.label),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.read<NavProvider>().goTo(d.id);
                  },
                ),
              const Divider(),
            ],
            ListTile(
              leading:
                  Icon(Icons.verified_user_outlined, color: AppColors.muted),
              title: const Text('Verify receipt'),
              subtitle: const Text(
                  'Check a transfer before handing over goods'),
              onTap: () {
                Navigator.pop(sheet);
                _openVerifier(context);
              },
            ),
            if (user.isAdmin)
              ListTile(
                leading: Icon(Icons.settings_outlined, color: AppColors.muted),
                title: const Text('Settings'),
                subtitle: const Text('Shop profile, tax, receipt, backup'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()));
                },
              ),
            if (user.isAdmin)
              ListTile(
                leading: Icon(Icons.manage_accounts_outlined,
                    color: AppColors.muted),
                title: const Text('Staff accounts'),
                subtitle: const Text('Add cashiers, reset passwords'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UsersScreen()));
                },
              ),
            ListTile(
              leading: Icon(Icons.lock_reset_outlined, color: AppColors.muted),
              title: const Text('Change password'),
              onTap: () {
                Navigator.pop(sheet);
                _showChangePassword(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.logout_rounded, color: AppColors.danger),
              title: Text('Sign out',
                  style: TextStyle(color: AppColors.danger)),
              subtitle: const Text('Back to the login screen'),
              onTap: () {
                Navigator.pop(sheet);
                _confirmSignOut(context);
              },
            ),
            const SizedBox(height: AppSpace.s2),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need your password to sign back in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (sure == true && context.mounted) {
      await context.read<AuthProvider>().logout();
    }
  }


  void _showChangePassword(BuildContext context) {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final confirmC = TextEditingController();
    String? error;

    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Icon(Icons.lock_reset_outlined, size: 22, color: AppColors.primary),
            SizedBox(width: AppSpace.s2 + 2),
            Text('Change password'),
          ]),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: oldC,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Current password'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newC,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password (min 6 chars)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmC,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.s2),
                    child: Text(error!, style: TextStyle(color: AppColors.danger, fontSize: 13)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (newC.text != confirmC.text) {
                  setD(() => error = 'New passwords do not match.');
                  return;
                }
                final err = await context.read<AuthProvider>().changePassword(oldC.text, newC.text);
                if (!c.mounted) return;
                if (err != null) {
                  setD(() => error = err);
                } else {
                  Navigator.pop(c);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password updated')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact phone bottom bar: 54dp of content over the safe area, 20dp
/// icons and 10dp labels. Exactly FOUR primary tabs (Sell / Products /
/// Sales / Customers) plus a trailing "More" slot that holds everything
/// else (see kBarTabs). No chunky M3 indicator strip — active tabs get a
/// small pill behind the icon instead; [moreActive] lights the More pill
/// whenever the current destination lives inside the More sheet.
class _PhoneNavBar extends StatelessWidget {
  final List<_NavItem> items;
  final int selectedIndex;
  final bool moreActive;
  final int lowStock;
  final int lowStockIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onMore;

  const _PhoneNavBar({
    required this.items,
    required this.selectedIndex,
    required this.moreActive,
    required this.lowStock,
    required this.lowStockIndex,
    required this.onSelect,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.borderSoft)),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) Expanded(child: _cell(i)),
          ],
        ),
      ),
    );
  }

  Widget _cell(int i) {
    final item = items[i];
    final selected = item.isMore ? moreActive : i == selectedIndex;
    final color = selected ? AppColors.primary : AppColors.muted;
    final badge = (i == lowStockIndex && lowStock > 0) ? lowStock : null;

    final icon = Icon(selected ? item.activeIcon : item.icon, size: 20, color: color);
    final Widget iconArea = badge != null
        ? Badge.count(
            count: badge,
            textStyle: const TextStyle(
                fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white),
            child: icon)
        : icon;

    return InkWell(
      onTap: item.isMore ? onMore : () => onSelect(i),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? AppColors.primarySoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: iconArea,
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              letterSpacing: 0.1,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
