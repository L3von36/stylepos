import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'users_screen.dart';

/// Shop settings (admin): profile, currency, tax, loyalty.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _shopName;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  late final TextEditingController _footer;
  late final TextEditingController _curCode;
  late final TextEditingController _curSymbol;
  late final TextEditingController _tax;
  late final TextEditingController _lowStock;
  late final TextEditingController _loyalty;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _shopName = TextEditingController(text: s.shopName);
    _address = TextEditingController(text: s.shopAddress);
    _phone = TextEditingController(text: s.shopPhone);
    _footer = TextEditingController(text: s.receiptFooter);
    _curCode = TextEditingController(text: s.currencyCode);
    _curSymbol = TextEditingController(text: s.currencySymbol);
    _tax = TextEditingController(text: s.taxRate.toString());
    _lowStock = TextEditingController(text: s.lowStockDefault.toString());
    _loyalty = TextEditingController(text: s.loyaltyStep.toString());
  }

  @override
  void dispose() {
    for (final c in [
      _shopName, _address, _phone, _footer,
      _curCode, _curSymbol, _tax, _lowStock, _loyalty,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<AppSettings>().save(
          shopName: _shopName.text.trim(),
          shopAddress: _address.text.trim(),
          shopPhone: _phone.text.trim(),
          receiptFooter: _footer.text.trim(),
          currencyCode: _curCode.text.trim(),
          currencySymbol: _curSymbol.text.trim(),
          taxRate: double.tryParse(_tax.text) ?? 0,
          lowStockDefault: int.tryParse(_lowStock.text) ?? 5,
          loyaltyStep: int.tryParse(_loyalty.text) ?? 0,
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PageHeader(
                title: 'Settings',
                subtitle: 'Shop profile, currency, tax and loyalty configuration',
              ),

              // --- shop profile ---
              SectionCard(
                icon: Icons.storefront_outlined,
                title: 'Shop profile',
                subtitle: 'Shown on receipts and around the app',
                children: [
                  TextField(
                    controller: _shopName,
                    decoration: const InputDecoration(
                        labelText: 'Shop name (shown on receipts)'),
                  ),
                  const SizedBox(height: 13),
                  TextField(
                    controller: _address,
                    decoration:
                        const InputDecoration(labelText: 'Address (receipts)'),
                  ),
                  const SizedBox(height: 13),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'Phone (receipts)'),
                  ),
                  const SizedBox(height: 13),
                  TextField(
                    controller: _footer,
                    decoration: const InputDecoration(
                        labelText: 'Receipt footer message'),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // --- currency & tax ---
              SectionCard(
                icon: Icons.payments_outlined,
                title: 'Currency & tax',
                subtitle: 'Applied to all prices, totals and reports',
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _curCode,
                          decoration: const InputDecoration(
                              labelText: 'Currency code (e.g. KES, USD)'),
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: TextField(
                          controller: _curSymbol,
                          decoration: const InputDecoration(
                              labelText: 'Symbol (e.g. KSh, \$, €)'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tax,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Tax rate (%)', helperText: '0 disables tax'),
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: TextField(
                          controller: _lowStock,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Default low-stock threshold'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  TextField(
                    controller: _loyalty,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Loyalty: 1 point per this amount spent',
                      helperText: '0 disables loyalty points',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save settings'),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // --- users ---
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.manage_accounts_outlined,
                        color: AppColors.primary, size: 22),
                  ),
                  title: const Text('Staff accounts'),
                  subtitle: const Text('Add cashiers, reset passwords, deactivate'),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.faint),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UsersScreen())),
                ),
              ),

              // --- about ---
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.storefront_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('StylePOS',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink)),
                            const SizedBox(height: 2),
                            Text(
                              'Offline point of sale for clothing shops\n'
                              'Signed in as ${auth.user?.name ?? "-"} '
                              '(${(auth.user?.isAdmin ?? false) ? "admin" : "cashier"})',
                              style: const TextStyle(
                                  fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
