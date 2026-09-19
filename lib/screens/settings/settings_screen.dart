import 'dart:convert' show base64Decode, base64Encode;
import 'dart:io' show File, Platform, exit;
import 'dart:typed_data' show Uint8List;

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/database.dart';
import '../../services/audit.dart';
import '../../services/backup_service.dart';
import '../../services/branches.dart';
import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import 'cloud_sync_card.dart';

/// Shop settings (admin): profile (read-only until edited), tax & points,
/// receipt branding, cloud sync and backup. Manager tools (approval PIN,
/// audit trail) live in Reports.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  bool _editingProfile = false;
  late final TextEditingController _shopName;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  late final TextEditingController _footer;
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
    _tax = TextEditingController(text: s.taxRate.toString());
    _lowStock = TextEditingController(text: s.lowStockDefault.toString());
    _loyalty = TextEditingController(text: s.loyaltyStep.toString());
  }

  @override
  void dispose() {
    for (final c in [
      _shopName, _address, _phone, _footer,
      _tax, _lowStock, _loyalty,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final name = _shopName.text.trim();
    if (name.isEmpty) {
      await _toast('Shop name cannot be empty', error: true);
      return;
    }
    await context.read<AppSettings>().save(
          shopName: name,
          shopAddress: _address.text.trim(),
          shopPhone: _phone.text.trim(),
          receiptFooter: _footer.text.trim(),
        );
    if (!mounted) return;
    setState(() => _editingProfile = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Shop profile saved')));
  }

  void _cancelProfileEdit() {
    // Re-seed the controllers from the stored values — unsaved typing is
    // discarded, exactly like a form dialog's Cancel.
    final s = context.read<AppSettings>();
    _shopName.text = s.shopName;
    _address.text = s.shopAddress;
    _phone.text = s.shopPhone;
    _footer.text = s.receiptFooter;
    setState(() => _editingProfile = false);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _saveTaxAndPoints() async {
    await context.read<AppSettings>().save(
          taxRate: (double.tryParse(_tax.text) ?? 0).clamp(0.0, 100.0),
          lowStockDefault: (int.tryParse(_lowStock.text) ?? 5).clamp(0, 999),
          loyaltyStep: (int.tryParse(_loyalty.text) ?? 0).clamp(0, 1000000),
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
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
    final me = context.read<AuthProvider>().user;
    setState(() => _busy = true);
    try {
      final path = await BackupService.createBackup();
      if (!mounted) return;
      // The zip exists now — count this as a real backup even if the
      // share/save step is cancelled, so the reminder stays honest.
      await context.read<AppSettings>().markBackedUp();
      await Audit.add('backup_exported', p.basename(path),
          userId: me?.id, userName: me?.name);
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
                  foregroundColor: AppColors.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace everything')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final me = context.read<AuthProvider>().user;
      await Audit.add('restore', p.basename(picked),
          userId: me?.id, userName: me?.name);
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

  /// Opens a picker, downscales the image to a receipt-friendly PNG and
  /// stores it as base64 in the settings (synced to every device).
  Future<void> _pickLogo() async {
    final sp = context.read<AppSettings>();
    try {
      Uint8List? bytes;
      if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
        final x = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 92,
          maxWidth: 1400,
        );
        if (x == null) return;
        bytes = await x.readAsBytes();
      } else {
        final f = await openFile(acceptedTypeGroups: const [
          XTypeGroup(label: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp']),
        ]);
        if (f == null) return;
        bytes = await File(f.path).readAsBytes();
      }
      if (bytes.lengthInBytes > 10 * 1024 * 1024) {
        await _toast('That image is too large — please pick one under 10 MB', error: true);
        return;
      }
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        await _toast('Could not read that image', error: true);
        return;
      }
      final resized = decoded.width > 480
          ? img.copyResize(decoded, width: 480)
          : decoded;
      final b64 = base64Encode(img.encodePng(resized));
      await sp.save(receiptLogo: b64);
      await _toast('Receipt logo updated');
    } catch (_) {
      await _toast('Could not load that image', error: true);
    }
  }

  Future<void> _removeLogo() async {
    final sp = context.read<AppSettings>();
    await sp.save(receiptLogo: '');
    await _toast('Logo removed');
  }

  /// Human label for the last backup stamp on this device.
  String _lastBackupLabel(AppSettings s) {
    final t = s.lastBackupAt;
    if (t == null || t <= 0) return 'never on this device';
    final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final days = today.difference(day).inDays;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    if (days == 0) return 'today at $hh:$mm';
    if (days == 1) return 'yesterday at $hh:$mm';
    if (days < 30) return '$days days ago';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// One read-only shop-profile line: icon + label on the left, the value
  /// on the right (placeholder dash when empty). Tapping "Edit profile"
  /// swaps these rows for the editable form.
  Widget _profileRow(IconData icon, String label, String value,
      {String? placeholder}) {
    final empty =
        value.trim().isEmpty || value == AppSettings.defaultShopName;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.s1 + 1),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.muted),
          const SizedBox(width: AppSpace.s2),
          Text(label,
              style: TextStyle(
                  fontFamily: 'Carlito', fontSize: 12.5, color: AppColors.muted)),
          const Spacer(),
          const SizedBox(width: AppSpace.s3),
          Flexible(
            child: Text(
              empty ? (placeholder ?? '—') : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'Carlito',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: empty ? AppColors.faint : AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final s = context.watch<AppSettings>();

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

              // --- shop profile (read-only until "Edit profile") ---
              SectionCard(
                icon: Icons.storefront_outlined,
                title: 'Shop profile',
                subtitle: 'Shown on receipts and around the app',
                children: [
                  if (!_editingProfile) ...[
                    _profileRow(Icons.badge_outlined, 'Shop name',
                        s.shopName, placeholder: AppSettings.defaultShopName),
                    _profileRow(Icons.location_on_outlined, 'Address',
                        s.shopAddress),
                    _profileRow(Icons.phone_outlined, 'Phone', s.shopPhone),
                    _profileRow(Icons.receipt_long_outlined,
                        'Receipt footer', s.receiptFooter),
                    const SizedBox(height: AppSpace.s3),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => setState(() => _editingProfile = true),
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        label: const Text('Edit profile'),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: _shopName,
                      autofocus: true,
                      decoration: const InputDecoration(
                          labelText: 'Shop name (shown on receipts)'),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    TextField(
                      controller: _address,
                      decoration: const InputDecoration(
                          labelText: 'Address (receipts)'),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'Phone (receipts)'),
                    ),
                    const SizedBox(height: AppSpace.s3),
                    TextField(
                      controller: _footer,
                      decoration: const InputDecoration(
                          labelText: 'Receipt footer message'),
                    ),
                    const SizedBox(height: AppSpace.s4),
                    Row(
                      children: [
                        TextButton(
                          onPressed: _cancelProfileEdit,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 46)),
                            onPressed: _saveProfile,
                            icon: const Icon(Icons.save_outlined, size: 18),
                            label: const Text('Save profile'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // --- appearance (applies instantly, no save button) ---
              SectionCard(
                icon: Icons.contrast_rounded,
                title: 'Appearance',
                subtitle: 'Light, dark, or follow the device — applies instantly',
                children: [
                  SegmentedButton<String>(
                    style: primarySegmentStyle(),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: 'system',
                          label: Text('System'),
                          icon: Icon(Icons.brightness_auto_outlined, size: 17)),
                      ButtonSegment(
                          value: 'light',
                          label: Text('Light'),
                          icon: Icon(Icons.light_mode_outlined, size: 17)),
                      ButtonSegment(
                          value: 'dark',
                          label: Text('Dark'),
                          icon: Icon(Icons.dark_mode_outlined, size: 17)),
                    ],
                    selected: {s.themeModeName},
                    onSelectionChanged: (sel) =>
                        context.read<AppSettings>().save(themeMode: sel.first),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // --- receipt logo ---
              SectionCard(
                icon: Icons.branding_watermark_outlined,
                title: 'Receipt logo',
                subtitle: 'Shown at the top of every PDF receipt',
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceTint,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: AppColors.borderSoft),
                        ),
                        child: (s.receiptLogoB64 != null)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(AppRadius.md),
                                child: Image.memory(
                                  base64Decode(s.receiptLogoB64!),
                                  width: 62,
                                  height: 62,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                ),
                              )
                            : Icon(Icons.image_outlined,
                                size: 26, color: AppColors.faint),
                      ),
                      const SizedBox(width: AppSpace.s3),
                      Expanded(
                        child: Text(
                          'A square logo works best (PNG or JPG). It is resized '
                          'for the 80mm roll and synced to every device that '
                          'prints your receipts.',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.muted,
                              height: 1.45),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.s3),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeThumbColor: AppColors.primary,
                    title: const Text('Show logo on receipts'),
                    value: s.receiptShowLogo,
                    onChanged: (v) =>
                        context.read<AppSettings>().save(receiptShowLogo: v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeThumbColor: AppColors.primary,
                    title: const Text('Show cashier name on receipts'),
                    value: s.receiptShowCashier,
                    onChanged: (v) =>
                        context.read<AppSettings>().save(receiptShowCashier: v),
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pickLogo,
                        icon: const Icon(Icons.upload_outlined, size: 18),
                        label: Text(s.receiptLogoB64 == null
                            ? 'Choose logo…'
                            : 'Replace logo…'),
                      ),
                      if (s.receiptLogoB64 != null) ...[
                        const SizedBox(width: AppSpace.s2),
                        TextButton.icon(
                          onPressed: _removeLogo,
                          icon: const Icon(Icons.delete_outline_rounded, size: 18),
                          label: const Text('Remove'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // --- tax & points (currency is fixed to Ethiopian Birr) ---
              SectionCard(
                icon: Icons.payments_outlined,
                title: 'Tax & points',
                subtitle: 'Prices and totals are in Ethiopian Birr (Br)',
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.s3, vertical: AppSpace.s2 + 2),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.currency_exchange_rounded,
                            size: 17, color: AppColors.primary),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: Text(
                            'Currency: Ethiopian Birr — code ETB, shown as '
                            '"Br" on prices, receipts and reports',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 12,
                                color: AppColors.primaryDark),
                          ),
                        ),
                      ],
                    ),
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
                    onPressed: _saveTaxAndPoints,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s4),

              // --- payment methods (checkout picker follows this) ---
              SectionCard(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Payment methods',
                subtitle: 'What the till offers at checkout — applies instantly',
                children: [
                  for (final entry in const [
                    ('cash', 'Cash', Icons.payments_outlined),
                    ('card', 'Card', Icons.credit_card_rounded),
                    ('mobile', 'Mobile money', Icons.smartphone_rounded),
                  ])
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppColors.primary,
                      title: Row(children: [
                        Icon(entry.$3, size: 18, color: AppColors.primary),
                        const SizedBox(width: AppSpace.s2),
                        Text(entry.$2),
                      ]),
                      value: s.paymentMethods.contains(entry.$1),
                      onChanged: (on) {
                        final next = [...s.paymentMethods];
                        if (on == true) {
                          if (!next.contains(entry.$1)) next.add(entry.$1);
                        } else {
                          next.remove(entry.$1);
                        }
                        // Never leave the till with zero methods.
                        if (next.isEmpty) return;
                        context.read<AppSettings>().save(paymentMethods: next);
                      },
                    ),
                  Text(
                    'Cashiers can only charge the methods you tick here.',
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 11,
                        color: AppColors.faint),
                  ),
                ],
              ),

              const SizedBox(height: AppSpace.s4),

              // --- branches (multi-shop) ---
              const _BranchesCard(),

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
                          fontSize: 12,
                          color: AppColors.muted,
                          height: 1.45),
                    ),
                    const SizedBox(height: AppSpace.s2),
                    Row(
                      children: [
                        Icon(Icons.history_rounded,
                            size: 15,
                            color: s.backupReminderDue
                                ? AppColors.warning
                                : AppColors.success),
                        const SizedBox(width: 6),
                        Text(
                          'Last backup: ${_lastBackupLabel(s)}',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: s.backupReminderDue
                                  ? AppColors.warning
                                  : AppColors.body),
                        ),
                      ],
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
                      Icon(Icons.info_outline_rounded,
                          size: 16, color: AppColors.faint),
                      const SizedBox(width: 8),
                      Expanded(
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
                            Text('Sami',
                                style: TextStyle(
                                    fontFamily: 'Carlito',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.ink)),
                            const SizedBox(height: AppSpace.s1),
                            Text(
                              'Point of sale for clothing shops\n'
                              'Signed in as ${auth.user?.name ?? "-"} '
                              '(${(auth.user?.isAdmin ?? false) ? "Manager" : "Sales"})',
                              style: TextStyle(
                                  fontFamily: 'Carlito', fontSize: 12, color: AppColors.muted, height: 1.4),
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

// ---------- branches (multi-shop) ----------

/// Multi-branch management: every shop the manager owns (their root shop +
/// its branches), create a new branch, or switch this device to another
/// branch. Switching wipes the local mirror and re-pulls the target
/// branch's data — each branch is a fully separate workspace.
class _BranchesCard extends StatefulWidget {
  const _BranchesCard();

  @override
  State<_BranchesCard> createState() => _BranchesCardState();
}

class _BranchesCardState extends State<_BranchesCard> {
  List<BranchShop>? _shops;
  bool _busy = false;
  String _currentId = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final shops = await Branches.list();
    // Which branch does THIS device mirror right now? The remembered
    // cloud_shop_id is kept in step by sign-in / branch switching.
    String current = '';
    try {
      final db = await DB.instance();
      final rows = await db.query('settings',
          where: 'key = ?', whereArgs: ['cloud_shop_id']);
      current = rows.isEmpty ? '' : (rows.first['value'] as String? ?? '');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _shops = shops;
        _currentId = current;
      });
    }
  }

  Future<void> _createBranch() async {
    final auth = context.read<AuthProvider>();
    final name = TextEditingController();
    final error = <String>[];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Icon(Icons.add_business_outlined, size: 22, color: AppColors.primary),
            const SizedBox(width: AppSpace.s2),
            const Text('New branch'),
          ]),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Branch name (e.g. Westlands branch)',
                  helperText: 'A separate workspace with its own stock, '
                      'staff and sales — you keep full control',
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s2),
                  child: Text(error.first,
                      style: TextStyle(
                          fontFamily: 'Carlito',
                          fontSize: 12,
                          color: AppColors.danger)),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setD(() {
                    error
                      ..clear()
                      ..add('Give the branch a name.');
                  });
                  return;
                }
                Navigator.pop(c, true);
              },
              child: const Text('Create branch'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final (id, err) = await Branches.create(name.text,
        actorUserId: auth.user?.id, actorName: auth.user?.name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
      return;
    }
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Branch created — use "Switch" to move this device '
            'to it (or keep running the current shop here)'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _switch(BranchShop target) async {
    final auth = context.read<AuthProvider>();
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Switch to ${target.name}?'),
        content: SizedBox(
          width: 400,
          child: Text(
            'This device will show ${target.name}\'s catalog, staff, sales '
            'and reports instead of the current shop. Your other branch '
            'data stays safe in the cloud — switch back any time.\n\n'
            'The switch wipes and re-pulls this device\'s local data, so '
            'stay online until it finishes.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Switch branch')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final err = await Branches.switchTo(target,
        actorUserId: auth.user?.id, actorName: auth.user?.name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
      return;
    }
    await context.read<AppSettings>().load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Now running ${target.name}'),
        behavior: SnackBarBehavior.floating,
      ));
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      icon: Icons.account_tree_outlined,
      title: 'Branches',
      subtitle: 'Run more than one shop from this account',
      children: [
        if (_shops == null)
          const Padding(
            padding: EdgeInsets.all(AppSpace.s3),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_shops!.length <= 1) ...[
          Text(
            'Multi-branch lets you run several shops (locations) from one '
            'account. Every branch has its own catalog, staff, stock, sales '
            'and reports — and you hop between them from here.',
            style: TextStyle(
                fontFamily: 'Carlito', fontSize: 12, color: AppColors.body),
          ),
          const SizedBox(height: AppSpace.s3),
          OutlinedButton.icon(
            onPressed: _busy ? null : _createBranch,
            icon: const Icon(Icons.add_business_outlined, size: 18),
            label: const Text('Create first branch'),
          ),
        ] else ...[
          for (final shop in _shops!)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.s2),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.s3, vertical: AppSpace.s2),
              decoration: BoxDecoration(
                color: shop.id == _currentId
                    ? AppColors.primarySoft
                    : AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderSoft),
              ),
              child: Row(children: [
                Icon(
                  shop.isBranch
                      ? Icons.store_mall_directory_outlined
                      : Icons.storefront_rounded,
                  size: 19,
                  color: AppColors.primary,
                ),
                const SizedBox(width: AppSpace.s2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(shop.name,
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                      Text(
                          '${shop.id == _currentId ? 'This device · ' : ''}'
                          '${shop.isBranch ? 'Branch' : 'Main shop'} · code ${shop.code}',
                          style: TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 11,
                              color: AppColors.muted)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _switch(shop),
                  child: const Text('Switch'),
                ),
              ]),
            ),
          const SizedBox(height: AppSpace.s2),
          OutlinedButton.icon(
            onPressed: _busy ? null : _createBranch,
            icon: const Icon(Icons.add_business_outlined, size: 18),
            label: const Text('Add branch'),
          ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.s2),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}
