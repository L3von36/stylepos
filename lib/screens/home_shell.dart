import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'customers/customers_screen.dart';
import 'pos/pos_screen.dart';
import 'products/products_screen.dart';
import 'reports/reports_screen.dart';
import 'sales/sales_screen.dart';
import 'settings/settings_screen.dart';
import '../state/auth.dart';
import '../state/nav.dart';
import '../state/settings.dart';
import '../widgets/ui.dart';

class _Dest {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final Widget page;
  const _Dest(this.icon, this.activeIcon, this.label, this.page);
}

/// Adaptive app scaffold: NavigationRail on wide screens (desktop/tablet),
/// drawer navigation on narrow phones.
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

    final all = [
      _Dest(Icons.point_of_sale_outlined, Icons.point_of_sale_rounded, 'POS', const PosScreen()),
      _Dest(Icons.inventory_2_outlined, Icons.inventory_2_rounded, 'Products', const ProductsScreen()),
      _Dest(Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Sales', const SalesScreen()),
      _Dest(Icons.people_outline, Icons.people_alt_rounded, 'Customers', const CustomersScreen()),
      if (user.isAdmin)
        _Dest(Icons.insights_outlined, Icons.insights_rounded, 'Reports', const ReportsScreen()),
      if (user.isAdmin)
        _Dest(Icons.settings_outlined, Icons.settings_rounded, 'Settings', const SettingsScreen()),
    ];
    final index = nav.index.clamp(0, all.length - 1);

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
                      user.isAdmin ? 'Admin' : 'Cashier',
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
          onPressed: () async {
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
          },
        ),
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
                onDestinationSelected: (i) => nav.go(i),
                extended: extended,
                minExtendedWidth: 192,
                leading: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s4, bottom: AppSpace.s3),
                  child: extended
                      ? null
                      : const SizedBox.shrink(),
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

      // narrow layout
      return Scaffold(
        appBar: appBar,
        drawer: Drawer(
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(AppRadius.xl)), // M3 modal drawer
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + AppSpace.s5,
                    left: AppSpace.s5,
                    right: AppSpace.s5,
                    bottom: AppSpace.s6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF4338CA), Color(0xFF4F46E5), Color(0xFF6D28D9)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 24),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    Text(settings.shopName,
                        style: const TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    const SizedBox(height: AppSpace.s1),
                    Text('${user.name} · ${user.isAdmin ? 'Admin' : 'Cashier'}',
                        style: TextStyle(
                            fontFamily: 'Carlito',
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.8))),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3, vertical: AppSpace.s3),
                  children: [
                    for (var i = 0; i < all.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: ListTile(
                          leading: Icon(i == index ? all[i].activeIcon : all[i].icon),
                          title: Text(all[i].label),
                          selected: i == index,
                          selectedTileColor: AppColors.primarySoft,
                          selectedColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md)),
                          onTap: () {
                            nav.go(i);
                            Navigator.pop(context);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: IndexedStack(index: index, children: [for (final d in all) d.page]),
      );
    });
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
