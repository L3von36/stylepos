import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'customers/customers_screen.dart';
import 'pos/pos_screen.dart';
import 'products/products_screen.dart';
import 'reports/reports_screen.dart';
import 'sales/sales_screen.dart';
import 'settings/settings_screen.dart';
import '../models/user.dart';
import '../state/auth.dart';
import '../state/nav.dart';
import '../state/settings.dart';
import '../widgets/ui.dart';

class _Dest {
  final NavId id;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final Widget page;
  const _Dest(this.id, this.icon, this.activeIcon, this.label, this.page);
}

/// Adaptive app scaffold: NavigationRail on wide screens (desktop/tablet),
/// and a Material 3 [NavigationBar] at the bottom on phones — the standard
/// one-hand mobile pattern for POS apps.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final settings = context.watch<AppSettings>();
    final nav = context.watch<NavProvider>();
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();

    // Role-aware destinations: the shop manager sees reports too, while
    // the sales person gets a focused selling workspace. Settings lives
    // in the app bar (manager only) to keep the bottom bar at 4-5 tabs.
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
        _Dest(NavId.reports, Icons.insights_outlined, Icons.insights_rounded, 'Reports',
            const ReportsScreen()),
    ];
    final index = all.indexWhere((d) => d.id == nav.id).clamp(0, all.length - 1);

    // Phones cannot fit gear + password + name pill + logout next to the
    // shop name — they collapse to gear (manager) + one avatar button that
    // opens an account sheet.
    final narrow = MediaQuery.sizeOf(context).width < 720;

    final appBar = AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
              ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.storefront_rounded, size: 17, color: Colors.white),
          ),
          const SizedBox(width: AppSpace.s2 + 2),
          Text(settings.shopName),
        ],
      ),
      actions: [
        if (user.isAdmin)
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: 21),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        if (narrow)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.s2),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => _showAccountSheet(context, user),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                ),
                child: Text(
                  user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primaryDark),
                ),
              ),
            ),
          )
        else ...[
          IconButton(
            tooltip: 'Change password',
            icon: const Icon(Icons.lock_reset_outlined, size: 21),
            onPressed: () => _showChangePassword(context),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.s1 + 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => _showChangePassword(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s1),
                decoration: BoxDecoration(
                  color: AppColors.surfaceTint,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.borderSoft),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary),
                      ),
                    ),
                    const SizedBox(width: AppSpace.s2),
                    Text(user.name,
                        style: const TextStyle(
                            fontFamily: 'Carlito', fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink)),
                    const SizedBox(width: AppSpace.s2),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.s2, vertical: 2),
                      decoration: BoxDecoration(
                        color: user.isAdmin ? AppColors.primarySoft : AppColors.infoSoft,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        user.isAdmin ? 'Manager' : 'Sales',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: user.isAdmin ? AppColors.primaryDark : AppColors.info),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout_rounded, size: 21),
            onPressed: () => _confirmSignOut(context),
          ),
        ],
        const SizedBox(width: AppSpace.s1),
      ],
    );

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      if (wide) {
        final extended = constraints.maxWidth >= 1240;
        return Scaffold(
          appBar: appBar,
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: (i) => nav.goTo(all[i].id),
                extended: extended,
                minExtendedWidth: 192,
                leading: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s4, bottom: AppSpace.s3),
                  child: extended ? null : const SizedBox.shrink(),
                ),
                labelType: extended
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                groupAlignment: -0.9,
                destinations: [
                  for (final d in all)
                    NavigationRailDestination(
                      icon: Icon(d.icon, size: 23),
                      selectedIcon: Icon(d.activeIcon, size: 23),
                      label: Text(d.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1, thickness: 1, color: AppColors.borderSoft),
              Expanded(child: IndexedStack(index: index, children: [for (final d in all) d.page])),
            ],
          ),
        );
      }

      // Phone layout: content + M3 bottom navigation bar.
      return Scaffold(
        appBar: appBar,
        body: IndexedStack(index: index, children: [for (final d in all) d.page]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => nav.goTo(all[i].id),
          height: 68,
          destinations: [
            for (final d in all)
              NavigationDestination(
                icon: Icon(d.icon, size: 23),
                selectedIcon: Icon(d.activeIcon, size: 23),
                label: d.label,
              ),
          ],
        ),
      );
    });
  }

  /// Compact account sheet for phones: who is signed in, change password,
  /// sign out.
  void _showAccountSheet(BuildContext context, AppUser user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
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
                            style: const TextStyle(
                                fontFamily: 'Carlito', fontSize: 16,
                                fontWeight: FontWeight.w700, color: AppColors.ink)),
                        Text(
                          '${user.isAdmin ? 'Manager' : 'Sales'} · ${user.email}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.lock_reset_outlined, color: AppColors.muted),
              title: const Text('Change password'),
              onTap: () {
                Navigator.pop(sheet);
                _showChangePassword(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.danger),
              title: const Text('Sign out',
                  style: TextStyle(color: AppColors.danger)),
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
          title: const Row(children: [
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
                    child: Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
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
