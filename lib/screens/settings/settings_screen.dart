import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth.dart';
import '../../state/settings.dart';
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
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- shop profile ---
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.storefront_outlined, size: 20),
                          const SizedBox(width: 8),
                          Text('Shop profile',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _shopName,
                        decoration: const InputDecoration(
                            labelText: 'Shop name (shown on receipts)'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _address,
                        decoration:
                            const InputDecoration(labelText: 'Address (receipts)'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration:
                            const InputDecoration(labelText: 'Phone (receipts)'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _footer,
                        decoration: const InputDecoration(
                            labelText: 'Receipt footer message'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // --- currency & tax ---
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.payments_outlined, size: 20),
                          const SizedBox(width: 8),
                          Text('Currency & tax',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _curCode,
                              decoration: const InputDecoration(
                                  labelText: 'Currency code (e.g. KES, USD)'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _curSymbol,
                              decoration: const InputDecoration(
                                  labelText: 'Symbol (e.g. KSh, \$, €)'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
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
                          const SizedBox(width: 12),
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
                      const SizedBox(height: 12),
                      TextField(
                        controller: _loyalty,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Loyalty: 1 point per this amount spent',
                          helperText: '0 disables loyalty points',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save settings'),
              ),
              const SizedBox(height: 12),

              // --- users ---
              Card(
                child: ListTile(
                  leading: const Icon(Icons.manage_accounts_outlined),
                  title: const Text('Staff accounts'),
                  subtitle: const Text('Add cashiers, reset passwords, deactivate'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UsersScreen())),
                ),
              ),

              // --- about ---
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('StylePOS'),
                  subtitle: Text(
                      'Offline point of sale for clothing shops\n'
                      'Signed in as ${auth.user?.name ?? "-"} '
                      '(${(auth.user?.isAdmin ?? false) ? "admin" : "cashier"})',
                      style: const TextStyle(fontSize: 12)),
                  isThreeLine: true,
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
