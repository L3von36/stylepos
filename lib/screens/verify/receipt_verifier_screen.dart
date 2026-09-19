import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/receipt_verify/models.dart';
import '../../services/receipt_verify/parsers.dart';
import '../../services/receipt_verify/verifier.dart';
import '../../state/auth.dart';
import '../../state/settings.dart';
import '../../widgets/ui.dart';
import '../pos/scan_dialog.dart';

/// Verify a customer's transfer receipt straight against the bank — the
/// shop's defence against fake payment screenshots (Telebirr, CBE, BOA,
/// M-Pesa, Dashen, Awash, Zemen, CBE Birr, Siinqee, eBirr).
///
/// Pick the bank, paste the reference / receipt link (or scan the QR on the
/// sender's phone), optionally set the amount you expect, and Sami shows
/// what the bank really recorded. Every check is kept in a local history so
/// disputes can be revisited later.
class ReceiptVerifierScreen extends StatefulWidget {
  /// Prefills the "amount to match" field (e.g. the open cart total).
  final double? initialExpectedAmount;

  const ReceiptVerifierScreen({super.key, this.initialExpectedAmount});

  @override
  State<ReceiptVerifierScreen> createState() => _ReceiptVerifierScreenState();
}

class _ReceiptVerifierScreenState extends State<ReceiptVerifierScreen> {
  late BankInfo _bank = kVerifyBanks.first;
  final _reference = TextEditingController();
  final _account = TextEditingController();
  final _phone = TextEditingController();
  final _expected = TextEditingController();

  bool _busy = false;
  ReceiptData? _receipt;
  VerifyFailure? _failure;
  double? _checkedExpected;

  List<CheckRecord> _recent = [];

  /// Camera QR scanning is an Android/iOS capability (mobile_scanner).
  bool get _canScan =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    if (widget.initialExpectedAmount != null &&
        widget.initialExpectedAmount! > 0) {
      _expected.text = widget.initialExpectedAmount!.toStringAsFixed(2);
    }
    _loadRecent();
  }

  @override
  void dispose() {
    _reference.dispose();
    _account.dispose();
    _phone.dispose();
    _expected.dispose();
    super.dispose();
  }

  double? get _expectedValue => double.tryParse(
      _expected.text.replaceAll(RegExp(r'[^0-9.]'), ''));

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _loadRecent() async {
    try {
      final recent = await ReceiptVerifier.recentChecks();
      if (mounted) setState(() => _recent = recent);
    } catch (_) {// history is a nice-to-have; never block the screen
    }
  }

  Future<void> _pasteReference() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _reference.text = text;
    // A pasted receipt link tells us the bank — switch to it for the user.
    if (looksLikeUrl(text)) {
      final detected = detectBankFromUrl(text);
      if (detected != null && mounted) {
        setState(() {
          final bank = bankById(detected.bank);
          if (bank != null) _bank = bank;
        });
      }
    }
  }

  Future<void> _scanQr() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const ScanDialog(title: 'Scan receipt QR code'),
    );
    if (code == null || code.trim().isEmpty || !mounted) return;
    final payload = code.trim();

    if (looksLikeUrl(payload)) {
      final detected = detectBankFromUrl(payload);
      if (detected != null) {
        final bank = bankById(detected.bank);
        if (bank != null) setState(() => _bank = bank);
        _reference.text = detected.reference;
        final detectedAccount = detected.account;
        if (detectedAccount != null) _account.text = detectedAccount;
      } else {
        _reference.text = payload;
      }
      await _verify();
      return;
    }

    // Non-URL payloads: BOA slips decrypt offline, Telebirr QRs carry an
    // encoded invoice number — hand the raw payload to the verifier.
    _reference.clear();
    await _verify(qrData: payload);
  }

  Future<void> _verify({String? qrData}) async {
    if (_busy) return;
    final reference = _reference.text.trim();
    if (reference.isEmpty && qrData == null) {
      setState(() => _failure = const VerifyFailure(
            VerifyErrorKind.badInput,
            'Enter the reference number or receipt link first.',
          ));
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
      _receipt = null;
    });

    final user = context.read<AuthProvider>().user;
    final input = VerifyInput(
      bankId: _bank.id,
      reference: reference,
      account: _bank.accountDigits > 0 ? _account.text.trim() : null,
      phone: _bank.requiresPhone ? _phone.text.trim() : null,
      qrData: qrData,
      expectedAmount: _expectedValue,
    );

    final result = await ReceiptVerifier.I.verify(input);
    _checkedExpected = _expectedValue;

    if (result.ok) {
      final r = result.receipt!;
      final status = _statusFor(r);
      await ReceiptVerifier.saveCheck(CheckRecord(
        bank: r.bankCode,
        bankName: r.bankName,
        reference: r.reference,
        status: status,
        expectedAmount: _checkedExpected,
        amount: r.amount,
        senderName: r.senderName,
        receiverName: r.receiverName,
        receiptDate: r.date,
        detail: CheckRecord.detailJson(r),
        checkedBy: user?.name ?? '',
        checkedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      )).catchError((_) {});
    } else {
      await ReceiptVerifier.saveCheck(CheckRecord(
        bank: _bank.id,
        bankName: _bank.name,
        reference: reference,
        status: 'failed',
        expectedAmount: _checkedExpected,
        amount: null,
        checkedBy: user?.name ?? '',
        checkedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      )).catchError((_) {});
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _receipt = result.receipt;
      _failure = result.failure;
    });
    _loadRecent();
  }

  String _statusFor(ReceiptData r) {
    final expected = _expectedValue;
    if (r.amount == null || expected == null) return 'verified';
    if ((r.amount! - expected).abs() < 0.01) return 'match';
    return 'mismatch';
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Verify receipt')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.s4),
            children: [
              if (kIsWeb) ...[
                _webNote(),
                const SizedBox(height: AppSpace.s3),
              ],
              _bankPicker(),
              const SizedBox(height: AppSpace.s3),
              _inputCard(settings),
              const SizedBox(height: AppSpace.s3),
              if (_busy) _busyCard(),
              if (!_busy && _receipt != null)
                _resultCard(_receipt!, _checkedExpected, settings),
              if (!_busy && _failure != null) _failureCard(_failure!),
              const SizedBox(height: AppSpace.s4),
              _recentSection(settings),
              const SizedBox(height: AppSpace.s6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _webNote() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.s3 + 2),
      decoration: BoxDecoration(
        color: AppColors.infoSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: AppColors.info),
          const SizedBox(width: AppSpace.s2 + 2),
          Expanded(
            child: Text(
              'Receipt checks talk directly to the banks. That works best in '
              'the Android or Windows app — on web, some banks may refuse the '
              'browser. BOA QR scans still verify offline.',
              style: TextStyle(fontSize: 12.5, color: AppColors.body, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bankPicker() {
    return SectionCard(
      icon: Icons.account_balance_rounded,
      title: 'Which bank or wallet?',
      subtitle: 'Pick where the customer paid from',
      children: [
        Wrap(
          spacing: AppSpace.s2,
          runSpacing: AppSpace.s2,
          children: [
            for (final bank in kVerifyBanks)
              _bankChip(bank),
          ],
        ),
      ],
    );
  }

  Widget _bankChip(BankInfo bank) {
    final selected = bank.id == _bank.id;
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => setState(() {
        _bank = bank;
        _receipt = null;
        _failure = null;
      }),
      avatar: selected
          ? null
          : Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              child: Text(
                bank.initials,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryDark,
                ),
              ),
            ),
      label: Text(
        bank.shortName,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      labelPadding: const EdgeInsets.symmetric(horizontal: AppSpace.s2),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _inputCard(AppSettings settings) {
    return SectionCard(
      icon: Icons.receipt_long_outlined,
      title: _bank.shortName,
      subtitle: _bank.helper,
      children: [
        TextField(
          controller: _reference,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _verify(),
          decoration: InputDecoration(
            labelText: _bank.referenceLabel,
            hintText: _bank.referenceHint,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded, size: 19),
                onPressed: _pasteReference,
              ),
              if (_canScan)
                IconButton(
                  tooltip: 'Scan QR',
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                  onPressed: _scanQr,
                ),
              const SizedBox(width: AppSpace.s1),
            ]),
          ),
        ),
        if (_bank.accountDigits > 0) ...[
          const SizedBox(height: AppSpace.s3),
          TextField(
            controller: _account,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: _bank.accountDigits,
            decoration: InputDecoration(
              labelText: _bank.accountLabel,
              isDense: true,
              counterText: '',
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        if (_bank.requiresPhone) ...[
          const SizedBox(height: AppSpace.s3),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Payer phone number',
              hintText: '09…',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: AppSpace.s3),
        TextField(
          controller: _expected,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Amount they should have paid (optional)',
            hintText: '0.00',
            isDense: true,
            border: const OutlineInputBorder(),
            helperText:
                'We compare it with what the bank recorded and flag any difference.',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: AppSpace.s4),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            minimumSize: const Size.fromHeight(46),
          ),
          onPressed: _busy ? null : _verify,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.onBrand))
              : const Icon(Icons.verified_outlined, size: 19),
          label: Text(_busy ? 'Checking with ${_bank.shortName}…'
              : 'Verify with ${_bank.shortName}'),
        ),
      ],
    );
  }

  Widget _busyCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.s4),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: AppSpace.s3),
            Expanded(
              child: Text(
                'Asking ${_bank.name} about this receipt…',
                style: TextStyle(fontSize: 13.5, color: AppColors.body),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── result ────────────────────────────────────────────────────────────────

  Widget _resultCard(ReceiptData r, double? expected, AppSettings settings) {
    final match = expected != null &&
        r.amount != null &&
        (r.amount! - expected).abs() < 0.01;
    final mismatch = expected != null &&
        r.amount != null &&
        (r.amount! - expected).abs() >= 0.01;

    final Color headColor;
    final String headText;
    final IconData headIcon;
    if (mismatch) {
      headColor = AppColors.danger;
      headText = 'Amount does not match';
      headIcon = Icons.cancel_rounded;
    } else if (match) {
      headColor = AppColors.success;
      headText = 'Verified — amount matches';
      headIcon = Icons.verified_rounded;
    } else {
      headColor = AppColors.success;
      headText = 'Receipt verified';
      headIcon = Icons.verified_rounded;
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: headColor,
            padding: const EdgeInsets.all(AppSpace.s3 + 2),
            child: Row(
              children: [
                Icon(headIcon, size: 22, color: AppColors.onError),
                const SizedBox(width: AppSpace.s2 + 2),
                Expanded(
                  child: Text(
                    headText,
                    style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onBrand),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpace.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (r.amount != null) ...[
                  Center(
                    child: Text(
                      settings.money(r.amount!),
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: mismatch ? AppColors.danger : AppColors.ink,
                        height: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.s1),
                  Center(
                    child: Text(
                      '${r.bankName} · ${r.reference}',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ),
                  if (mismatch) ...[
                    const SizedBox(height: AppSpace.s2),
                    Container(
                      padding: const EdgeInsets.all(AppSpace.s2 + 2),
                      decoration: BoxDecoration(
                        color: AppColors.dangerSoft,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        'You expected ${settings.money(expected)} — the receipt '
                        'shows ${settings.money(r.amount!)}. Do NOT hand over '
                        'the goods until this is resolved.',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.danger,
                            fontWeight: FontWeight.w600,
                            height: 1.4),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpace.s3),
                ] else ...[
                  Text('Receipt found, but the bank did not report an amount.',
                      style: TextStyle(fontSize: 13, color: AppColors.body)),
                  const SizedBox(height: AppSpace.s3),
                ],
                _resultRow('From', _joinNameAcc(r.senderName, r.senderAccount)),
                _resultRow('To', _joinNameAcc(
                    r.receiverName ?? r.bankAccountName,
                    r.receiverAccount ?? r.bankAccountNumber)),
                _resultRow('Date', r.date),
                if (r.transactionStatus != null)
                  _resultRow('Status', r.transactionStatus),
                if (r.reason != null && r.reason!.isNotEmpty)
                  _resultRow('Reason', r.reason),
                if (r.branch != null && r.branch!.isNotEmpty)
                  _resultRow('Branch', r.branch),
                if (r.note != null) ...[
                  const SizedBox(height: AppSpace.s2),
                  Container(
                    padding: const EdgeInsets.all(AppSpace.s2 + 2),
                    decoration: BoxDecoration(
                      color: AppColors.warningSoft,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: AppSpace.s2),
                        Expanded(
                          child: Text(
                            r.note!,
                            style: TextStyle(
                                fontSize: 12, color: AppColors.warning,
                                height: 1.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _joinNameAcc(String? name, String? account) {
    final parts = [if (name != null && name.isNotEmpty) name,
      if (account != null && account.isNotEmpty) account];
    if (parts.isEmpty) return null;
    return parts.join('  ·  ');
  }

  Widget _resultRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.s1 + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13.5,
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _failureCard(VerifyFailure f) {
    final isBadInput = f.kind == VerifyErrorKind.badInput;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isBadInput ? Icons.edit_note_rounded : Icons.error_outline_rounded,
                    size: 20,
                    color: isBadInput ? AppColors.warning : AppColors.danger),
                const SizedBox(width: AppSpace.s2 + 2),
                Expanded(
                  child: Text(
                    isBadInput ? 'Almost there' : 'Could not verify',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s2),
            Text(f.message,
                style: TextStyle(
                    fontSize: 13, color: AppColors.body, height: 1.45)),
            if (f.tips.isNotEmpty) ...[
              const SizedBox(height: AppSpace.s2),
              for (final tip in f.tips)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.s1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('•  ', style: TextStyle(color: AppColors.faint)),
                      Expanded(
                        child: Text(tip,
                            style: TextStyle(
                                fontSize: 12.5, color: AppColors.muted,
                                height: 1.4)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ── recent checks ─────────────────────────────────────────────────────────

  Widget _recentSection(AppSettings settings) {
    return SectionCard(
      icon: Icons.history_rounded,
      title: 'Recent checks',
      subtitle: 'Kept on this device only',
      action: _recent.isEmpty
          ? null
          : TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear check history?'),
                    content: const SizedBox(
                        width: 360,
                        child: Text(
                            'This removes every receipt check recorded on this '
                            'device. Sales and receipts are not affected.')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Keep')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Clear')),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ReceiptVerifier.clearChecks();
                  _loadRecent();
                }
              },
              child: const Text('Clear'),
            ),
      children: [
        if (_recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.s4),
            child: Text(
              'No checks yet — verify a transfer above and it will be listed '
              'here for follow-up.',
              style: TextStyle(fontSize: 12.5, color: AppColors.muted,
                  height: 1.5),
            ),
          )
        else
          ...[for (final c in _recent) _recentRow(c, settings)],
      ],
    );
  }

  Widget _recentRow(CheckRecord c, AppSettings settings) {
    final (Color color, IconData icon, String label) = switch (c.status) {
      'match' => (AppColors.success, Icons.check_circle_outline_rounded, 'Match'),
      'verified' => (AppColors.success, Icons.verified_outlined, 'Verified'),
      'mismatch' => (AppColors.danger, Icons.cancel_outlined, 'Mismatch'),
      _ => (AppColors.muted, Icons.help_outline_rounded, 'Failed'),
    };
    final when = DateTime.fromMillisecondsSinceEpoch(c.checkedAt * 1000);
    final whenText = '${when.month}/${when.day} ${_hhmm(when)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.s2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpace.s2 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.bankName} · ${c.reference}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (c.amount != null) settings.money(c.amount!),
                    if (c.senderName != null && c.senderName!.isNotEmpty)
                      'from ${c.senderName}',
                    whenText,
                    if (c.checkedBy.isNotEmpty) 'by ${c.checkedBy}',
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: AppColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s2),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ],
      ),
    );
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
