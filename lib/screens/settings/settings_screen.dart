import 'dart:io' show File, Platform, exit;

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/backup_service.dart';
import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'cloud_sync_card.dart';
import 'users_screen.dart';

/// Shop settings (admin): profile, currency, tax, loyalty.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
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
          taxRate: (double.tryParse(_tax.text) ?? 0).clamp(0.0, 100.0),
          lowStockDefault: (int.tryParse(_lowStock.text) ?? 5).clamp(0, 999),
          loyaltyStep: (int.tryParse(_loyalty.text) ?? 0).clamp(0, 1000000),
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Settings saved')));
    }
  }

  Future<void> _toast(String msg, {bool error = false}) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.danger : null,
    ));
  }

  /// Creates the backup zip, then shares it (phones) or saves it (desktop).
  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final path = await BackupService.createBackup();
      if (!mounted) return;
      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(ShareParams(
          files: [XFile(path, mimeType: 'application/zip')],
          subject: 'Sami backup',
          text: 'Sami shop backup — keep this file somewhere safe.',
        ));
      } else {
        final loc = await getSaveLocation(suggestedName: p.basename(path));
        if (loc != null) {
          await File(path).copy(loc.path);
          if (mounted) _toast('Backup saved');
        }
      }
    } on BackupException catch (e) {
      await _toast(e.message, error: true);
    } catch (_) {
      await _toast('Backup failed — please try again', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks a backup file, confirms, then replaces all shop data on this
  /// device. Prompts for an app restart afterwards.
  Future<void> _restoreBackup() async {
    String? picked;
    if (Platform.isAndroid || Platform.isIOS) {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      picked = res?.files.single.path;
    } else {
      final f = await openFile(acceptedTypeGroups: const [
        XTypeGroup(
            label: 'Sami backup', extensions: ['stylepos', 'zip']),
      ]);
      picked = f?.path;
    }
    if (picked == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: const SizedBox(
          width: 400,
          child: Text(
              'Everything currently on this device — products, sales, '
              'customers and photos — will be REPLACED by the backup. '
              'This cannot be undone.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace everything')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await BackupService.restoreBackup(picked);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore complete'),
          content: const SizedBox(
            width: 360,
            child: Text(
                'Your shop data was restored. Close and reopen Sami '
                'now to finish.'),
          ),
          actions: [
            FilledButton(
              onPressed: () => exit(0),
              child: const Text('Close Sami'),
            ),
          ],
        ),
      );
    } on BackupException catch (e) {
      await _toast(e.message, error: true);
    } catch (_) {
      await _toast('Restore failed — the backup file may be damaged',
          error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // Pushed as a standalone page from the app bar (manager only), so it
    // owns a Scaffold with a back button.
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s4, AppSpace.s4, AppSpace.s6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No in-page heading — the app bar already says "Settings"
              // (same pattern as the pushed Staff accounts screen).

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
                  const SizedBox(height: AppSpace.s3),
                  TextField(
                    controller: _address,
                    decoration:
                        const InputDecoration(labelText: 'Address (receipts)'),
                  ),
                  const SizedBox(height: AppSpace.s3),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration:
                        const InputDecoration(labelText: 'Phone (receipts)'),
                  ),
                  const SizedBox(height: AppSpace.s3),
                  TextField(
                    controller: _footer,
                    decoration: const InputDecoration(
                        labelText: 'Receipt footer message'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

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
                      const SizedBox(width: AppSpace.s3),
                      Expanded(
                        child: TextField(
                          controller: _curSymbol,
                          decoration: const InputDecoration(
                              labelText: 'Symbol (e.g. KSh, \$, €)'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.s3),
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
                      const SizedBox(width: AppSpace.s3),
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
                  const SizedBox(height: AppSpace.s3),
                  TextField(
                    controller: _loyalty,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Loyalty: 1 point per this amount spent',
                      helperText: '0 disables loyalty points',
                    ),
                  ),
                  const SizedBox(height: AppSpace.s4),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save settings'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // --- users ---
              Card(
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.s4, vertical: AppSpace.s2),
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(AppRadius.md),
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

              const SizedBox(height: AppSpace.s4),

              // --- cloud sync ---
              const CloudSyncCard(),

              const SizedBox(height: AppSpace.s4),

              // --- backup & restore (needs a local file system) ---
              if (!kIsWeb) ...[
                SectionCard(
                  icon: Icons.backup_outlined,
                  title: 'Backup & restore',
                  subtitle:
                      'One file with your whole shop — database + product photos',
                  children: [
                    Text(
                      'Export a backup and keep it away from this device '
                      '(WhatsApp to yourself, email, USB, Google Drive). '
                      'If this phone is ever lost or replaced, Restore puts '
                      'everything back. Make a fresh backup at least weekly.',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.muted,
                          height: 1.45),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 46)),
                            onPressed: _busy ? null : _exportBackup,
                            icon: const Icon(Icons.file_upload_outlined,
                                size: 18),
                            label: const Text('Export backup'),
                          ),
                        ),
                        const SizedBox(width: AppSpace.s3),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              foregroundColor: AppColors.danger,
                            ),
                            onPressed: _busy ? null : _restoreBackup,
                            icon: const Icon(Icons.restore_outlined, size: 18),
                            label: const Text('Restore'),
                          ),
                        ),
                      ],
                    ),
                    if (_busy) ...[
                      const SizedBox(height: AppSpace.s3),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpace.s4),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(AppSpace.s3),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceTint,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppColors.borderSoft),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          size: 16, color: AppColors.faint),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'File backups are not available on the web — your '
                          'data is kept in this browser and synced to the '
                          'cloud. Use the phone or PC app for file backups.',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12,
                              color: AppColors.muted,
                              height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.s4),
              ],

              // --- about ---
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.s4),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF4F46E5), Color(0xFF6D28D9)],
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: const Icon(Icons.storefront_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: AppSpace.s4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Sami',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink)),
                            const SizedBox(height: AppSpace.s1),
                            Text(
                              'Offline point of sale for clothing shops\n'
                              'Signed in as ${auth.user?.name ?? "-"} '
                              '(${(auth.user?.isAdmin ?? false) ? "Manager" : "Sales"})',
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
              const SizedBox(height: AppSpace.s6),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
