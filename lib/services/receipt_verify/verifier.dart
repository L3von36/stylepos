import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../data/database.dart';
import 'http_client_factory.dart';
import 'models.dart';
import 'parsers.dart';
import 'pdf_text.dart';

/// One verification attempt's outcome: either a [ReceiptData] or a
/// user-ready [VerifyFailure], plus how long the bank took.
class VerifyResult {
  final ReceiptData? receipt;
  final VerifyFailure? failure;
  final int durationMs;
  const VerifyResult.receipt(ReceiptData this.receipt, this.durationMs)
      : failure = null;
  const VerifyResult.failed(VerifyFailure this.failure, this.durationMs)
      : receipt = null;
  bool get ok => receipt != null;
}

/// The receipt verifier orchestrator — a Dart port of 1RB/cheki's verifier.
///
/// Flow: resolve the input (QR payload / pasted link / raw reference) →
/// validate → fetch the bank's own receipt endpoint with retries → parse →
/// [VerifyResult]. Also owns the local verification history (offline-first:
/// past checks stay queryable without network).
class ReceiptVerifier {
  ReceiptVerifier._();
  static final ReceiptVerifier I = ReceiptVerifier._();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
  static const _cbeHeaders = {
    'X-App-ID': 'd1292e42-7400-49de-a2d3-9731caa4c819',
    'X-App-Version': '0a01980b-9859-1369-8198-59f403820000',
    'Accept': 'application/json',
  };

  // ── public entry ──────────────────────────────────────────────────────────

  Future<VerifyResult> verify(VerifyInput input) async {
    final sw = Stopwatch()..start();
    try {
      final resolved = _resolve(input);
      if (resolved is _Failure) {
        return VerifyResult.failed(resolved.failure, sw.elapsedMilliseconds);
      }
      if (resolved is _Done) {
        // e.g. BOA QR — the whole receipt came out of the QR itself.
        return _receiptFrom(resolved.bank, resolved.parsed,
            resolved.fromQr, sw.elapsedMilliseconds);
      }
      // The only remaining outcome is the fetch plan.
      final plan = resolved as _Plan;

      final fetched = await _fetch(plan);
      if (fetched is! _Response) {
        final failure = (fetched as _Failure).failure;
        return VerifyResult.failed(failure, sw.elapsedMilliseconds);
      }
      final parsed = _parse(plan, fetched);
      if (!parsed.verified) {
        return VerifyResult.failed(
          VerifyFailure(
            VerifyErrorKind.notFound,
            'No receipt found for “${plan.reference}” at ${plan.bank.name}.',
            tips: const [
              'Double-check every character of the reference.',
              'Ask the sender to re-share the receipt link or show the QR.',
            ],
          ),
          sw.elapsedMilliseconds,
        );
      }
      return _receiptFrom(
          plan.bank, parsed, plan.fromQr, sw.elapsedMilliseconds);
    } catch (_) {
      return VerifyResult.failed(
        VerifyFailure(VerifyErrorKind.unreadable,
            'Something went wrong while checking this receipt.',
            tips: ['Try again — the bank may be busy.']),
        sw.elapsedMilliseconds,
      );
    }
  }

  VerifyResult _receiptFrom(
      BankInfo bank, Parsed parsed, bool fromQr, int durationMs) {
    var note = parsed.note;
    if (fromQr && note == null) {
      note = 'Scanned from the QR on the receipt.';
    }
    return VerifyResult.receipt(
      ReceiptData(
        verified: true,
        bankCode: bank.id,
        bankName: bank.name,
        reference: parsed.reference ?? '',
        senderName: parsed.senderName,
        senderAccount: parsed.senderAccount,
        receiverName: parsed.receiverName,
        receiverAccount: parsed.receiverAccount,
        amount: parsed.amount,
        currency: parsed.currency,
        date: parsed.date,
        branch: parsed.branch,
        reason: parsed.reason,
        transactionType: parsed.transactionType,
        transactionStatus: parsed.transactionStatus,
        invoiceNumber: parsed.invoiceNumber,
        bankAccountNumber: parsed.bankAccountNumber,
        bankAccountName: parsed.bankAccountName,
        note: note,
        fromQr: fromQr,
      ),
      durationMs,
    );
  }

  // ── input resolution ──────────────────────────────────────────────────────

  _Outcome _resolve(VerifyInput input) {
    var bankId = input.bankId;
    var reference = input.reference.trim();
    String? account = input.account?.trim();
    var fromQr = false;

    // QR payloads first: BOA decrypts offline; URLs auto-detect the bank;
    // Telebirr QRs carry the invoice number in an encoded blob.
    final qr = input.qrData?.trim();
    if (qr != null && qr.isNotEmpty) {
      fromQr = true;
      if (bankId == 'boa' && !looksLikeUrl(qr)) {
        final parsed = decryptBoaQr(qr);
        if (parsed == null || parsed.reference == null) {
          return _Failure(const VerifyFailure(
            VerifyErrorKind.unreadable,
            'Could not read that QR as a Bank of Abyssinia slip.',
            tips: ['Make sure the whole QR is inside the frame and well lit.'],
          ));
        }
        return _planFromParsed(input, 'boa', parsed, fromQr: true);
      }
      if (looksLikeUrl(qr)) {
        final detected = detectBankFromUrl(qr);
        if (detected == null) {
          return _Failure(const VerifyFailure(
            VerifyErrorKind.badInput,
            'That QR holds a link this app does not recognise.',
            tips: ['Type the reference number manually instead.'],
          ));
        }
        bankId = detected.bank;
        reference = detected.reference;
        account ??= detected.account;
      } else if (bankId == 'telebirr') {
        final invoice = extractTelebirrInvoiceFromQr(qr);
        if (invoice == null) {
          return _Failure(const VerifyFailure(
            VerifyErrorKind.unreadable,
            'Could not read that QR as a Telebirr receipt code.',
            tips: ['Copy the receipt number from the SMS instead.'],
          ));
        }
        reference = invoice;
      } else {
        reference = qr;
      }
    }

    // Pasted links auto-detect the bank.
    if (reference.isNotEmpty && looksLikeUrl(reference)) {
      final detected = detectBankFromUrl(reference);
      if (detected == null) {
        return _Failure(const VerifyFailure(
          VerifyErrorKind.badInput,
          'Could not detect the bank from that link.',
          tips: [
            'Paste the link exactly as the sender shared it.',
            'Or pick the bank above and type the reference number.',
          ],
        ));
      }
      bankId = detected.bank;
      reference = detected.reference;
      account ??= detected.account;
    }

    if (reference.isEmpty && qr == null) {
      return _Failure(const VerifyFailure(
        VerifyErrorKind.badInput,
        'Enter the reference number, receipt link, or scan the QR.',
      ));
    }

    final bank = bankById(bankId);
    if (bank == null) {
      if (bankId == 'cbe-legacy') {
        return _Failure(const VerifyFailure(
          VerifyErrorKind.unsupported,
          'CBE retired the old FT-reference receipts. Ask the sender for the '
          'new receipt link (mbreciept.cbe.com.et) or have them show the QR '
          'in the CBE app.',
        ));
      }
      return _Failure(VerifyFailure(
        VerifyErrorKind.unsupported,
        'That bank is not supported yet.',
      ));
    }

    if (bank.accountDigits > 0 && (account == null || account.isEmpty)) {
      return _Failure(VerifyFailure(
        VerifyErrorKind.badInput,
        '${bank.name} also needs ${bank.accountLabel.toLowerCase()}.',
      ));
    }
    if (bank.requiresPhone && (input.phone == null || input.phone!.trim().isEmpty)) {
      return _Failure(VerifyFailure(
        VerifyErrorKind.badInput,
        '${bank.name} also needs the payer phone number.',
      ));
    }

    return _Plan(bank, reference, account, input.phone?.trim(), fromQr);
  }

  /// BOA QR verification completes offline — no fetch, no network needed.
  _Outcome _planFromParsed(VerifyInput input, String bankId, Parsed parsed,
      {required bool fromQr}) {
    final bank = bankById(bankId)!;
    return _Done(bank, parsed, fromQr);
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Uri _buildUri(BankInfo bank, String reference, String? account, String? phone) {
    switch (bank.id) {
      case 'telebirr':
        return Uri.parse('https://transactioninfo.ethiotelecom.et/receipt/$reference');
      case 'cbe':
        return Uri.parse(
            'https://Mb.cbe.com.et/api/v1/transactions/public/transaction-detail/$reference');
      case 'boa':
        final suffix = (account ?? '').length > 5
            ? account!.substring(account.length - 5)
            : (account ?? '');
        return Uri.parse(
            'https://cs.bankofabyssinia.com/api/onlineSlip/getDetails/?id=$reference$suffix');
      case 'mpesa':
        return Uri.parse(
            'https://m-pesabusiness.safaricom.et/api/receipt/getReceipt?trxNo=$reference');
      case 'dashen':
        return Uri.parse('https://receipt.dashensuperapp.com/receipt/$reference');
      case 'awash':
        final ref = reference.startsWith('-') ? reference : '-$reference';
        return Uri.parse('https://awashpay.awashbank.com:8225/$ref');
      case 'zemen':
        return Uri.parse('https://share.zemenbank.com/rt/$reference/pdf');
      case 'cbebirr':
        return Uri.parse(
            'https://cbepay1.cbe.com.et/aureceipt?TID=${Uri.encodeQueryComponent(reference)}&PH=${Uri.encodeQueryComponent(phone ?? '')}');
      case 'siinqee':
        if (reference.startsWith('http')) return Uri.parse(reference);
        if (reference.contains('/')) {
          return Uri.parse('https://receipt.ebirr.com/$reference');
        }
        return Uri.parse('https://receipt.ebirr.com/siinqee/$reference');
      case 'ebirr':
        if (reference.startsWith('http')) return Uri.parse(reference);
        return Uri.parse('https://receipt.ebirr.com/$reference');
    }
    throw StateError('unreachable');
  }

  bool _isPdfBank(String id) => id == 'dashen' || id == 'zemen';

  Future<_Outcome> _fetch(_Plan plan) async {
    final bank = plan.bank;
    final uri = _buildUri(bank, plan.reference, plan.account, plan.phone);
    final timeout = Duration(seconds: _isPdfBank(bank.id) ? 25 : 15);
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept': _isPdfBank(bank.id)
          ? 'application/pdf,*/*'
          : 'text/html,application/json,*/*',
      if (bank.id == 'cbe') ..._cbeHeaders,
    };
    final client = createVerifyClient(allowBadCert: bank.allowBadCertificate);

    try {
      for (var attempt = 0; attempt <= 2; attempt++) {
        try {
          final resp = await client.get(uri, headers: headers).timeout(timeout);
          if (resp.statusCode == 404) {
            return _Failure(VerifyFailure(
              VerifyErrorKind.notFound,
              'The ${bank.name} receipt service says “not found”.',
              tips: const [
                'Check the reference for typos.',
                'If you pasted a link, make sure nothing was cut off.',
              ],
            ));
          }
          if (resp.statusCode >= 500 && attempt < 2) {
            await Future.delayed(Duration(milliseconds: 800 << attempt));
            continue;
          }
          if (resp.statusCode != 200) {
            return _Failure(VerifyFailure(
              VerifyErrorKind.network,
              '${bank.name} answered with an unexpected response '
                  '(HTTP ${resp.statusCode}).',
              tips: const ['Try again in a moment.'],
            ));
          }
          return _Response(
            bytes: resp.bodyBytes,
            bodyText: utf8.decode(resp.bodyBytes, allowMalformed: true),
          );
        } on TimeoutException {
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 800 << attempt));
            continue;
          }
        } catch (_) {
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 800 << attempt));
            continue;
          }
        }
      }
    } finally {
      client.close();
    }

    final String message;
    final tips = <String>[];
    if (kIsWeb) {
      message =
          'The web build cannot call ${bank.name} directly — browsers block '
          'cross-site requests to the bank.';
      tips
        ..add('Use the Android or Windows app for one-tap verification.')
        ..add('On web, ask the sender to open the receipt link so you can read it.');
    } else if (bank.geoBlocked && _outsideEthiopiaGuess()) {
      message =
          '${bank.name} blocks requests from outside Ethiopia. Turn off any '
          'VPN and try again.';
    } else {
      message = 'Could not reach ${bank.name}. Check your internet connection.';
      tips
        ..add('Mobile data or Wi-Fi must be on.')
        ..add('The bank service may be down — try again in a minute.');
    }
    return _Failure(VerifyFailure(VerifyErrorKind.network, message, tips: tips));
  }

  bool _outsideEthiopiaGuess() {
    // The geo-block is the likeliest culprit when the device clock sits in a
    // time zone far from Ethiopia (UTC+3) — e.g. a VPN user abroad.
    try {
      if (kIsWeb) return false;
      final offset = DateTime.now().timeZoneOffset.inHours;
      return offset < 1 || offset > 5;
    } catch (_) {
      return false;
    }
  }

  // ── parsing ───────────────────────────────────────────────────────────────

  Parsed _parse(_Plan plan, _Response resp) {
    final id = plan.bank.id;
    if (_isPdfBank(id)) {
      final magic = resp.bytes.length > 4 &&
          resp.bytes[0] == 0x25 && resp.bytes[1] == 0x50 && // %P
          resp.bytes[2] == 0x44 && resp.bytes[3] == 0x46; // DF
      if (!magic) return Parsed.notFound;
      final text = extractPdfText(resp.bytes);
      return id == 'dashen' ? parseDashenPdfText(text) : parseZemenPdfText(text);
    }
    switch (id) {
      case 'cbe':
        return parseCbeNewJson(resp.bodyText);
      case 'boa':
        return parseBoaJson(resp.bodyText);
      case 'mpesa':
        return parseMpesaJson(resp.bodyText);
      case 'telebirr':
        return parseTelebirrHtml(resp.bodyText);
      case 'awash':
        return parseAwashHtml(resp.bodyText);
      case 'cbebirr':
        return parseCbeBirrHtml(resp.bodyText);
      case 'siinqee':
      case 'ebirr':
        return parseEbirrHtml(resp.bodyText);
    }
    return Parsed.notFound;
  }

  // ── local history (offline-first, per device) ─────────────────────────────

  static Future<void> saveCheck(CheckRecord record) async {
    final db = await DB.instance();
    await db.insert('receipt_checks', record.toRow());
  }

  static Future<List<CheckRecord>> recentChecks({int limit = 8}) async {
    final db = await DB.instance();
    final rows = await db.query('receipt_checks',
        orderBy: 'checked_at DESC', limit: limit);
    return [for (final r in rows) CheckRecord.fromRow(r)];
  }

  static Future<void> clearChecks() async {
    final db = await DB.instance();
    await db.delete('receipt_checks');
  }
}

// ── private carriers ─────────────────────────────────────────────────────────

/// Sealed result of input resolution / fetching so type promotion works
/// without casts in [verify].
sealed class _Outcome {
  const _Outcome();
}

class _Plan implements _Outcome {
  final BankInfo bank;
  final String reference;
  final String? account;
  final String? phone;
  final bool fromQr;
  const _Plan(this.bank, this.reference, this.account, this.phone, this.fromQr);
}

class _Done implements _Outcome {
  final BankInfo bank;
  final Parsed parsed;
  final bool fromQr;
  const _Done(this.bank, this.parsed, this.fromQr);
}

class _Failure implements _Outcome {
  final VerifyFailure failure;
  const _Failure(this.failure);
}

class _Response implements _Outcome {
  final Uint8List bytes;
  final String bodyText;
  const _Response({required this.bytes, required this.bodyText});
}
