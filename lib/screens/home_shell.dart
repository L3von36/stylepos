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

class _Dest {
  final IconData icon;
  final String label;
  final Widget page;
  const _Dest(this.icon, this.label, this.page);
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
      _Dest(Icons.point_of_sale_rounded, 'POS', const PosScreen()),
      _Dest(Icons.inventory_2_outlined, 'Products', const ProductsScreen()),
      _Dest(Icons.receipt_long_outlined, 'Sales', const SalesScreen()),
      _Dest(Icons.people_outline, 'Customers', const CustomersScreen()),
      if (user.isAdmin) _Dest(Icons.insights_outlined, 'Reports', const ReportsScreen()),
      if (user.isAdmin) _Dest(Icons.settings_outlined, 'Settings', const SettingsScreen()),
    ];
    final index = nav.index.clamp(0, all.length - 1);

    final appBar = AppBar(
      title: Text(settings.shopName),
      actions: [
        IconButton(
          tooltip: 'Change password',
          icon: const Icon(Icons.lock_reset_outlined),
          onPressed: () => _showChangePassword(context),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Chip(
            avatar: Icon(
              user.isAdmin ? Icons.admin_panel_settings_outlined : Icons.badge_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: Text(user.name),
          ),
        ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
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
        const SizedBox(width: 4),
      ],
    );

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      if (wide) {
        return Scaffold(
          appBar: appBar,
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: (i) => nav.go(i),
                extended: constraints.maxWidth >= 1200,
                minExtendedWidth: 180,
                labelType: constraints.maxWidth >= 1200
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                leading: const SizedBox(height: 8),
                destinations: [
                  for (final d in all)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.icon, color: Theme.of(context).colorScheme.primary),
                      label: Text(d.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: IndexedStack(index: index, children: [for (final d in all) d.page])),
            ],
          ),
        );
      }

      // narrow layout
      return Scaffold(
        appBar: appBar,
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(settings.shopName, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('${user.name} · ${user.isAdmin ? 'Admin' : 'Cashier'}'),
                  ],
                ),
              ),
              for (var i = 0; i < all.length; i++)
                ListTile(
                  leading: Icon(all[i].icon),
                  title: Text(all[i].label),
                  selected: i == index,
                  onTap: () {
                    nav.go(i);
                    Navigator.pop(context);
                  },
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
          title: const Text('Change password'),
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
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
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
