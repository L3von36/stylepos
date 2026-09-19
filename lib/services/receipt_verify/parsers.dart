import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Dart port of the 1RB/cheki parsers (MIT): per-bank receipt parsing plus
/// URL detection and the BOA encrypted-QR decryption.
///
/// Every parser takes the raw bank response and returns a [Parsed] with the
/// fields the shop needs; `verified == false` means "bank answered but this
/// is not a receipt / not found".

class Parsed {
  final bool verified;
  final String? senderName, senderAccount, receiverName, receiverAccount;
  final double? amount;
  final String currency;
  final String? date, reference, branch, reason, transactionType,
      transactionStatus, invoiceNumber, bankAccountNumber, bankAccountName;
  final String? note;

  const Parsed({
    required this.verified,
    this.senderName,
    this.senderAccount,
    this.receiverName,
    this.receiverAccount,
    this.amount,
    this.currency = 'ETB',
    this.date,
    this.reference,
    this.branch,
    this.reason,
    this.transactionType,
    this.transactionStatus,
    this.invoiceNumber,
    this.bankAccountNumber,
    this.bankAccountName,
    this.note,
  });

  static const notFound = Parsed(verified: false);
}

double? _parseAmount(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

// ─────────────────────────────────────────────────────────────────────────────
// URL detection — paste a receipt link and we figure out bank + reference.
// Port of cheki's url-detector.ts.
// ─────────────────────────────────────────────────────────────────────────────

class UrlDetection {
  final String bank;
  final String reference;
  final String? account;
  const UrlDetection(this.bank, this.reference, [this.account]);
}

bool looksLikeUrl(String input) {
  final t = input.trim();
  return t.startsWith('http://') || t.startsWith('https://');
}

UrlDetection? detectBankFromUrl(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !looksLikeUrl(trimmed) || uri.host.isEmpty) return null;
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments;

  // CBE new: https://mbreciept.cbe.com.et/{shortId}
  if (host.contains('mbreciept.cbe.com.et') || host.contains('mb.cbe.com.et')) {
    if (segments.isNotEmpty) {
      return UrlDetection('cbe', segments.last);
    }
  }

  // CBE legacy: https://apps.cbe.com.et:100/?id=FT{ref}{last8}
  // The old endpoint was decommissioned by CBE — detected so we can show a
  // "ask for the new receipt link" message instead of a cryptic failure.
  if (host.contains('apps.cbe.com.et')) {
    final id = uri.queryParameters['id'];
    if (id != null && id.startsWith('FT') && id.length > 10) {
      return UrlDetection('cbe-legacy', id.substring(0, id.length - 8),
          id.substring(id.length - 8));
    }
  }

  // Telebirr: https://transactioninfo.ethiotelecom.et/receipt/{ref}
  if (host.contains('transactioninfo.ethiotelecom.et')) {
    if (segments.isNotEmpty) {
      return UrlDetection('telebirr', segments.last);
    }
  }

  // BOA: /slip/?trx={ref} or API ?id={ref}{last5}
  if (host.contains('bankofabyssinia.com')) {
    final trx = uri.queryParameters['trx'];
    final id = uri.queryParameters['id'];
    if (trx != null && trx.isNotEmpty) return UrlDetection('boa', trx);
    if (id != null && id.length > 5) {
      return UrlDetection('boa', id.substring(0, id.length - 5),
          id.substring(id.length - 5));
    }
    if (id != null && id.isNotEmpty) return UrlDetection('boa', id);
  }

  // Dashen: .../receipt/{ref} or Within-Dashen-Transfer-{REF}.pdf
  if (host.contains('dashensuperapp.com')) {
    final last = segments.isNotEmpty ? segments.last : '';
    final pdf = RegExp(r'Within-Dashen-Transfer-(.+?)\.pdf', caseSensitive: false)
        .firstMatch(last);
    if (pdf != null) return UrlDetection('dashen', pdf.group(1)!);
    if (last.isNotEmpty) return UrlDetection('dashen', last);
  }

  // Awash: https://awashpay.awashbank.com:8225/-{token}
  if (host.contains('awashbank.com')) {
    if (segments.isNotEmpty) {
      final ref =
          segments.last.replaceFirst(RegExp(r'^-'), '').replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      if (ref.isNotEmpty) return UrlDetection('awash', ref);
    }
  }

  // Zemen: https://share.zemenbank.com/rt/{ref}/pdf
  if (host.contains('zemenbank.com')) {
    if (segments.length >= 2) return UrlDetection('zemen', segments[1]);
    if (segments.length == 1) return UrlDetection('zemen', segments[0]);
  }

  // M-Pesa: ?trxNo={ref}
  if (host.contains('safaricom.et')) {
    final trx = uri.queryParameters['trxNo'];
    if (trx != null && trx.isNotEmpty) return UrlDetection('mpesa', trx);
  }

  // eBirr family: https://receipt.ebirr.com/{tenant}/{token}
  if (host.contains('receipt.ebirr.com')) {
    if (segments.length >= 2) {
      return UrlDetection('ebirr', '${segments[0]}/${segments[1]}');
    }
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// CBE (new system) — JSON API behind the mbreciept.cbe.com.et links.
// ─────────────────────────────────────────────────────────────────────────────

Parsed parseCbeNewJson(String body) {
  try {
    final json = jsonDecode(body) as Map<String, Object?>;
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) return Parsed.notFound;

    final amountRaw =
        (json['amountCredited'] ?? json['amountDebited']) as String?;
    final dates = json['dateTimes'] as List?;
    final details = json['paymentDetails'] as List?;

    return Parsed(
      verified: true,
      senderName: json['debitAccountHolder'] as String?,
      senderAccount: json['debitAccountNo'] as String?,
      receiverName: json['creditAccountHolder'] as String?,
      receiverAccount: json['creditAccountNo'] as String?,
      amount: amountRaw == null ? null : double.tryParse(amountRaw),
      currency: (json['creditCurrency'] as String?) ?? 'ETB',
      date: dates != null && dates.isNotEmpty ? dates.first as String : null,
      reference: id,
      reason: details != null && details.isNotEmpty ? details.first as String : null,
    );
  } catch (_) {
    return Parsed.notFound;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bank of Abyssinia — JSON API + AES-encrypted QR.
// ─────────────────────────────────────────────────────────────────────────────

Parsed parseBoaJson(String body) {
  try {
    final payload = jsonDecode(body) as Map<String, Object?>;
    final bodyList = payload['body'] as List?;
    if (bodyList == null || bodyList.isEmpty) return Parsed.notFound;
    final row = bodyList.first as Map<String, Object?>;
    if (row["Payer's Name"] == 'Invalid reference number') {
      return Parsed.notFound;
    }

    double? amount;
    final amtRaw = row['Transferred Amount']?.toString();
    if (amtRaw != null) amount = _parseAmount(amtRaw);

    return Parsed(
      verified: true,
      senderName: row['Source Account Name'] as String?,
      senderAccount: row['Source Account'] as String?,
      receiverName: row["Receiver's Name"] as String?,
      receiverAccount: row["Receiver's Account"] as String?,
      amount: amount,
      currency: (row['currency'] as String?) ?? 'ETB',
      date: row['Transaction Date'] as String?,
      reference: row['Transaction Reference'] as String?,
    );
  } catch (_) {
    return Parsed.notFound;
  }
}

/// BOA receipt QR payloads are AES-256-CBC encrypted. The key material is
/// published inside BOA's own receipt web app (same values cheki documents):
/// PBKDF2-SHA1, 10k iterations, static salt + IV. Decryption is fully
/// offline — scanning a BOA slip needs no network.
const String _boaQrPassword = 'ELqVy2g4pGWLUIKSa+1ijwpPy6eDxBFBLBPrJ24v/IA=';
const String _boaQrSalt = 'salt';
const String _boaQrIv = '1234567890123456';

Uint8List pbkdf2Sha1(List<int> password, List<int> salt, int iterations, int keyLen) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64));
  derivator.init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, keyLen));
  return derivator.process(Uint8List.fromList(password));
}

/// Decrypt + parse a BOA QR payload
/// (CSV: senderAccount,senderName,amount,reference,date,receiverAccount,receiverName).
Parsed? decryptBoaQr(String qrData) {
  try {
    final cipherText = base64Decode(qrData.trim());
    final key = pbkdf2Sha1(
        utf8.encode(_boaQrPassword), utf8.encode(_boaQrSalt), 10000, 32);
    final cbc = CBCBlockCipher(AESEngine());
    final padded = PaddedBlockCipherImpl(PKCS7Padding(), cbc);
    padded.init(
      false,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), Uint8List.fromList(utf8.encode(_boaQrIv))),
        null,
      ),
    );
    final plain = utf8.decode(padded.process(Uint8List.fromList(cipherText)),
        allowMalformed: true);
    final parts = plain.split(',').map((s) => s.trim()).toList();
    if (parts.length < 7) return null;

    final amount = parts[2].isEmpty ? null : _parseAmount(parts[2]);
    return Parsed(
      verified: true,
      senderAccount: parts[0],
      senderName: parts[1],
      amount: amount,
      reference: parts[3],
      date: parts[4],
      receiverAccount: parts[5],
      receiverName: parts[6],
      note:
          'BOA QR codes can be faked with third-party tools — treat this as a '
          'hint and confirm the money arrived in your own app or statement.',
    );
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Telebirr — HTML receipt page (bilingual English/Amharic).
// Port of cheki's telebirr.ts, including the mobile "Select All" fixes.
// ─────────────────────────────────────────────────────────────────────────────

const String _amPayerName = '\u12E8\u12A8\u12CD\u12FA\u12ED \u1235\u121B';
const String _amPayerTelebirr =
    '\u12E8\u12A8\u12CD\u12FA\u12ED \u124C\u12EC\u12A5\u1228\u1201 \u1230\u1201';
const String _amCreditedName =
    '\u12E8\u1300\u12AD\u12F0\u12E5 \u1320\u1241\u124B\u12ED \u1235\u121B';
const String _amCreditedAccount =
    '\u12E8\u1300\u12AD\u12F0\u12E5 \u1320\u1241\u124B\u12ED \u124C\u12EC\u12A5\u1228\u1201 \u1230\u1201';
const String _amBankAccount =
    '\u12E8\u1230\u12AD\u12AD \u12A0\u12AB\u12A0\u12CD\u12F5 \u1230\u1201\u120D';
const String _amStatus = '\u12E8\u12AD\u12CD\u12EB\u12F0 \u12D5\u12AD\u12D5\u12AD';
const String _amInvoice = '\u12E8\u12AD\u12CD\u12EB \u1230\u1201';
const String _amSettled = '\u12E8\u1300\u12A8\u12CD\u12F0\u12E5 \u1218\u12D5\u12D5';
const String _amStamp = '\u12E8\u1230\u12ED\u12A5\u12E5\u12EB \u12AD\u12CD\u12EB';
const String _amDiscount = '\u1305\u12D3\u12E5';
const String _amServiceFee = '\u12E8\u12A0\u1300\u12CD\u12CD\u12A5\u12EB \u12AD\u12CD\u12EB';
const String _amServiceFeeVat =
    '\u12E8\u12A0\u1300\u12CD\u12CD\u12A5\u12EB \u12AD\u12CD\u12EB \u1320\u12A5\u12A5\u1320';
const String _amTotalPaid =
    '\u1300\u12AD\u12AD\u12E8\u12E5 \u12E8\u1300\u12A8\u12CD\u12F0\u12E5';
const String _amInWords =
    '\u12E8\u1300\u12D3\u12E5 \u12E8\u12AD\u12AD \u12A0\u12CD\u12F0\u12EB';
const String _amMode = '\u12E8\u12AD\u12CD\u12EB \u12D5\u12F5';
const String _amReason = '\u12E8\u12AD\u12CD\u12EB \u121D\u12AD\u12D5\u12EB';
const String _amChannel = '\u12E8\u12AD\u12CD\u12EB \u1218\u12D5\u12CD';

List<String> _htmlToLines(String html) {
  return html
      .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<[^>]+>'), '\n')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// Mobile "Select All" copies of Telebirr receipts concatenate every label
/// onto one line — insert a newline before each known label so the line
/// parser can work (port of cheki's normalizeReceiptText).
String _normalizeTelebirrText(String text) {
  const labels = [
    'Service fee VAT', 'Service fee', 'Total Paid Amount',
    'Total Amount in words', 'Settled Amount', 'Discount Amount', 'Stamp Duty',
    'Payer telebirr no', 'Payer account type', 'Payer TIN No', 'Payer Name',
    'VAT Reg. Date', 'VAT Reg. No', 'Credited party account no',
    'Credited Party name', 'transaction status', 'Bank account number',
    'Invoice details', 'Invoice No.', 'Payment date', 'Payment Mode',
    'Payment Reason', 'Payment channel', 'Customer Note',
  ];
  final sorted = labels
      .map((l) => l.replaceAll(RegExp(r'[.*+?^${}()|[\]\\]'), r'\$&'))
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final regex = RegExp('(${sorted.join('|')})');
  return text.split('\n').map((line) {
    if (sorted.any((l) => line.trim() == l)) return line;
    return line.replaceAllMapped(regex, (m) => '\n${m[0]}');
  }).join('\n');
}

/// Detect the "all labels grouped, values dumped together" layout and
/// restructure so each label is followed by its own value (port of
/// cheki's restructureInvoiceSection).
String _restructureInvoiceSection(String text) {
  final lines = text.split('\n');
  final invoiceNoIdx =
      lines.indexWhere((l) => RegExp(r'Invoice\s*No\.?', caseSensitive: false).hasMatch(l));
  final settledIdx = lines.indexWhere((l) => l.contains('Settled Amount'));
  final stampIdx = lines.indexWhere((l) => l.contains('Stamp Duty'));

  if (invoiceNoIdx == -1 || settledIdx == -1 || stampIdx == -1) return text;
  if (settledIdx >= stampIdx) return text;

  final valueText = lines[settledIdx].replaceFirst(RegExp(r'Settled\s*Amount'), '').trim();
  final concat = RegExp(
          r'^([A-Z]{2,3}[A-Z0-9]{6,8})(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})(\d+\.?\d*)\s*Birr')
      .firstMatch(valueText);

  final newLines = List<String>.from(lines);
  if (concat != null) {
    newLines.removeRange(invoiceNoIdx, settledIdx + 1);
    newLines.insertAll(invoiceNoIdx, [
      'Invoice No.', concat.group(1)!, 'Payment date', concat.group(2)!,
      'Settled Amount', '${concat.group(3)} Birr',
    ]);
    return newLines.join('\n');
  }

  // Case 2: two-column HTML — labels first, then the values in order.
  const invoiceLabels = ['Invoice No.', 'Payment date', 'Settled Amount'];
  const knownLabels = [
    ...invoiceLabels, 'Stamp Duty', 'Discount Amount', 'Service fee',
    'Service fee VAT', 'Total Paid Amount', 'Total Amount in words',
  ];
  final values = <String>[];
  var valueEndIdx = settledIdx + 1;
  for (var i = settledIdx + 1; i < stampIdx && i < lines.length; i++) {
    if (knownLabels.any((label) => lines[i].contains(label))) continue;
    values.add(lines[i]);
    valueEndIdx = i + 1;
    if (values.length == 3) break;
  }
  if (values.length < 3) return text;
  if (!RegExp(r'^\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2}$').hasMatch(values[1])) {
    return text;
  }
  if (!RegExp(r'^\d[\d,]*\.?\d*\s*Birr$', caseSensitive: false).hasMatch(values[2])) {
    return text;
  }
  newLines.removeRange(invoiceNoIdx, valueEndIdx);
  newLines.insertAll(invoiceNoIdx, [
    'Invoice No.', values[0], 'Payment date', values[1], 'Settled Amount', values[2],
  ]);
  return newLines.join('\n');
}

Parsed parseTelebirrHtml(String html) {
  if (html.contains('This request is not correct') ||
      !html.toLowerCase().contains('telebirr receipt')) {
    return Parsed.notFound;
  }

  var text = _restructureInvoiceSection(_normalizeTelebirrText(_htmlToLines(html).join('\n')))
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // Find the value that follows a label (same line after the label, or one of
  // the next few lines), skipping Amharic echo lines.
  String? valAfter(String en, String? am) {
    for (var i = 0; i < text.length; i++) {
      final line = text[i];
      final hasEn = line.contains(en);
      final hasAm = am != null && line.contains(am);
      if (!hasEn && !hasAm) continue;
      final after = hasEn
          ? (line.split(en).length > 1 ? line.split(en)[1] : '')
          : (line.split(am!).length > 1 ? line.split(am)[1] : '');
      final cleaned = after.trim().replaceFirst(RegExp(r'^[.\-:]+'), '').trim();
      if (cleaned.isNotEmpty && !RegExp(r'^[\u1200-\u137F]').hasMatch(cleaned)) {
        return cleaned;
      }
      for (var j = i + 1; j < i + 4 && j < text.length; j++) {
        final next = text[j];
        if (RegExp(r'[\u1200-\u137F]').hasMatch(next) && next.contains('/')) continue;
        return next;
      }
    }
    return null;
  }

  double? birrAmount(String label, String? am) {
    for (var i = 0; i < text.length; i++) {
      final line = text[i];
      if (!line.contains(label) && (am == null || !line.contains(am))) continue;
      final here = RegExp(r'([0-9,]+\.?\d*)\s*(Birr|ETB)', caseSensitive: false)
          .firstMatch(line);
      if (here != null) return double.tryParse(here.group(1)!.replaceAll(',', ''));
      for (var j = i + 1; j < i + 4 && j < text.length; j++) {
        final m = RegExp(r'([0-9,]+\.?\d*)\s*(Birr|ETB)', caseSensitive: false)
            .firstMatch(text[j]);
        if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', ''));
      }
    }
    return null;
  }

  final senderName = valAfter('Payer Name', _amPayerName);
  final senderAccount = valAfter('Payer telebirr no', _amPayerTelebirr);
  final receiverName = valAfter('Credited Party name', _amCreditedName);
  final receiverAccount = valAfter('Credited party account no', _amCreditedAccount);

  // The real recipient bank account lives on the "Bank account number" line,
  // e.g. "1000370251685   Mr Mohammed Abdulwasi Reshid".
  String? bankAccountNumber, bankAccountName;
  final bankAccountRaw = valAfter('Bank account number', _amBankAccount);
  if (bankAccountRaw != null) {
    final m = RegExp(r'^(\d{10,})\s+(.+)$').firstMatch(bankAccountRaw);
    if (m != null) {
      bankAccountNumber = m.group(1);
      bankAccountName = m.group(2)?.trim();
    } else {
      bankAccountNumber = bankAccountRaw;
    }
  }

  final transactionStatus = valAfter('transaction status', _amStatus);
  final invoiceNumber = valAfter('Invoice No', _amInvoice);
  final settledAmount = birrAmount('Settled Amount', _amSettled);
  final stampDuty = birrAmount('Stamp Duty', _amStamp);
  final serviceFee = birrAmount('Service fee', _amServiceFee);
  final serviceFeeVat = birrAmount('Service fee VAT', _amServiceFeeVat);
  final totalPaid = birrAmount('Total Paid Amount', _amTotalPaid);
  final discountAmount = birrAmount('Discount Amount', _amDiscount);
  final amountInWords = valAfter('Total Amount in word', _amInWords);
  final paymentMode = valAfter('Payment Mode', _amMode);
  final reason = valAfter('Payment Reason', _amReason);
  final paymentChannel = valAfter('Payment channel', _amChannel);

  String? date;
  for (final line in text) {
    final m = RegExp(r'(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})').firstMatch(line);
    if (m != null) {
      date = m.group(1);
      break;
    }
  }

  final amount = settledAmount ??
      () {
        for (final line in text) {
          final m = RegExp(r'([0-9,]+\.?\d*)\s*(Birr|ETB)', caseSensitive: false)
              .firstMatch(line);
          if (m != null) return double.tryParse(m.group(1)!.replaceAll(',', ''));
        }
        return null;
      }();

  if (senderName == null && receiverName == null && amount == null) {
    return Parsed.notFound;
  }

  return Parsed(
    verified: true,
    senderName: senderName,
    senderAccount: senderAccount,
    receiverName: receiverName,
    receiverAccount: receiverAccount,
    amount: amount,
    date: date,
    reference: invoiceNumber,
    reason: reason,
    transactionStatus: transactionStatus,
    invoiceNumber: invoiceNumber,
    bankAccountNumber: bankAccountNumber,
    bankAccountName: bankAccountName,
    note: _telebirrNote(stampDuty, serviceFee, serviceFeeVat, totalPaid,
        discountAmount, amountInWords, paymentMode, paymentChannel),
  );
}

/// Telebirr receipts carry fee details — surface them through `note` so the
/// result card can show why "total paid" may differ from the settled amount.
String? _telebirrNote(
    double? stampDuty,
    double? serviceFee,
    double? serviceFeeVat,
    double? totalPaid,
    double? discountAmount,
    String? amountInWords,
    String? paymentMode,
    String? paymentChannel) {
  final bits = <String>[];
  if (totalPaid != null) bits.add('Total paid: $totalPaid Birr');
  if (serviceFee != null) bits.add('Service fee: $serviceFee Birr');
  if (serviceFeeVat != null) bits.add('Fee VAT: $serviceFeeVat Birr');
  if (stampDuty != null) bits.add('Stamp duty: $stampDuty Birr');
  if (discountAmount != null) bits.add('Discount: $discountAmount Birr');
  if (paymentMode != null) bits.add('Mode: $paymentMode');
  if (paymentChannel != null) bits.add('Channel: $paymentChannel');
  if (amountInWords != null && amountInWords.isNotEmpty) {
    bits.add('In words: $amountInWords');
  }
  return bits.isEmpty ? null : bits.join(' · ');
}

/// Telebirr QR payloads: base64 → utf-8 hex string → bytes → latin1 text
/// containing the invoice number as an 8–12 char A-Z0-9 run
/// (port of cheki's extractTelebirrInvoiceFromQr).
String? extractTelebirrInvoiceFromQr(String qrData) {
  try {
    final hexCandidate = utf8.decode(base64Decode(qrData.trim()), allowMalformed: true);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hexCandidate)) return null;
    final bytes = <int>[];
    for (var i = 0; i + 1 < hexCandidate.length; i += 2) {
      bytes.add(int.parse(hexCandidate.substring(i, i + 2), radix: 16));
    }
    final text = latin1.decode(bytes, allowInvalid: true);
    final m = RegExp(r'[A-Z0-9]{8,12}').firstMatch(text.toUpperCase());
    return m?.group(0);
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// M-Pesa — JSON.
// ─────────────────────────────────────────────────────────────────────────────

Parsed parseMpesaJson(String body) {
  try {
    final payload = jsonDecode(body) as Map<String, Object?>;
    final code = payload['responseCode'];
    if (code != null && code.toString() != '0') return Parsed.notFound;

    double? amount;
    final amountRaw = payload['amount']?.toString();
    if (amountRaw != null) amount = double.tryParse(amountRaw);

    return Parsed(
      verified: true,
      senderName: (payload['senderName'] ?? payload['payerName']) as String?,
      receiverName:
          (payload['receiverName'] ?? payload['creditPartyName']) as String?,
      amount: amount,
      currency: (payload['currency'] as String?) ?? 'ETB',
      date: (payload['transactionDate'] ?? payload['date']) as String?,
      reference: (payload['transactionId'] ?? payload['trxNo']) as String?,
    );
  } catch (_) {
    return Parsed.notFound;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Awash — HTML receipt served on the :8225 share endpoint.
// ─────────────────────────────────────────────────────────────────────────────

/// Finds "Label" → value in table-ish HTML text. First pass prefers lines
/// that are exactly the label; later passes accept same-line and next-line
/// values (port of cheki's findValue).
String? _findValue(List<String> lines, String label, [int startIndex = 0]) {
  final lower = label.toLowerCase();
  for (var i = startIndex; i < lines.length; i++) {
    final line = lines[i].trim().toLowerCase();
    if (line == lower || line == '$lower:' || line == '$lower=') {
      if (i + 1 < lines.length) {
        var j = i + 1;
        if (lines[j] == ':' && j + 1 < lines.length) j++;
        return lines[j];
      }
    }
  }
  for (var i = startIndex; i < lines.length; i++) {
    if (lines[i].toLowerCase().contains(lower)) {
      final m = RegExp('${RegExp.escape(label)}\\s*[:=]\\s*(.+)\$', caseSensitive: false)
          .firstMatch(lines[i]);
      if (m != null) return m.group(1)!.trim();
    }
  }
  for (var i = startIndex; i < lines.length; i++) {
    if (lines[i].toLowerCase().contains(lower)) {
      final remainder =
          lines[i].replaceFirst(RegExp('^.*?${RegExp.escape(label)}', caseSensitive: false), '').trim().toLowerCase();
      if (remainder.isNotEmpty && !remainder.startsWith(':')) continue;
      if (i + 1 < lines.length) {
        var j = i + 1;
        if (lines[j] == ':' && j + 1 < lines.length) j++;
        return lines[j];
      }
    }
  }
  return null;
}

Parsed parseAwashHtml(String html) {
  if (html.contains('Invalid receipt id') ||
      html.toLowerCase().contains('invalid receipt')) {
    return Parsed.notFound;
  }
  final lines = _htmlToLines(html);

  final senderName = _findValue(lines, 'Sender Name') ?? _findValue(lines, 'Customer Name');
  final senderAccount = _findValue(lines, 'Sender Account') ??
      _findValue(lines, 'Source Account') ??
      _findValue(lines, 'Account No');
  final receiverName = _findValue(lines, 'Receiver Name') ??
      _findValue(lines, 'Beneficiary name') ??
      _findValue(lines, 'Merchant') ??
      _findValue(lines, 'Recipient');
  final receiverAccount = _findValue(lines, 'Receiver Account') ??
      _findValue(lines, 'Beneficiary Account') ??
      _findValue(lines, 'Till Number') ??
      _findValue(lines, 'Phone Number');
  final reason = _findValue(lines, 'Reason');
  final transactionType = _findValue(lines, 'Transaction Type');
  final branch = _findValue(lines, 'Branch');
  final reference = _findValue(lines, 'Transaction ID');
  final date = _findValue(lines, 'Transaction Date') ?? _findValue(lines, 'Transaction Time');

  double? amount;
  final amountStr = _findValue(lines, 'Amount');
  if (amountStr != null) {
    final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(amountStr.replaceAll(',', ''));
    if (m != null) amount = double.tryParse(m.group(1)!);
  }

  final verified = senderName != null &&
      senderAccount != null &&
      (receiverName != null || receiverAccount != null) &&
      amount != null &&
      date != null;

  if (!verified) return Parsed.notFound;
  return Parsed(
    verified: true,
    reference: reference,
    senderName: senderName,
    senderAccount: senderAccount,
    receiverName: receiverName,
    receiverAccount: receiverAccount,
    amount: amount,
    date: date,
    branch: branch,
    reason: reason,
    transactionType: transactionType,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashen & Zemen — PDF receipts (text is extracted by pdf_text.dart first).
// ─────────────────────────────────────────────────────────────────────────────

/// Generic label-slicer: value = text between this label and the next
/// known label (port of cheki's Dashen/Zemen label walk).
Map<String, String> _sliceLabels(String text, List<String> labels) {
  final values = <String, String>{};
  for (var i = 0; i < labels.length; i++) {
    final label = labels[i];
    final startIdx = text.indexOf(label);
    if (startIdx == -1) continue;
    final valueStart = startIdx + label.length;
    var valueEnd = text.length;
    for (var j = i + 1; j < labels.length; j++) {
      final nextIdx = text.indexOf(labels[j], valueStart);
      if (nextIdx != -1) {
        valueEnd = nextIdx;
        break;
      }
    }
    values[label] = text.substring(valueStart, valueEnd).trim();
  }
  return values;
}

Parsed parseDashenPdfText(String text) {
  if (text.isEmpty || !text.contains('Dashen Bank')) return Parsed.notFound;

  const labels = [
    'Sender Name:', 'Sender Account Number:', 'Transaction Channel:',
    'Service Type:', 'Narrative:', 'Receiver Name:', 'Receiver Account Number:',
    'Instituton Name:', 'Transaction Reference:', 'Transfer Reference:',
    'Transaction Date:', 'Transaction Amount', 'Service Charge',
    'Excise Tax (15%):', 'DRRF Fee', 'VAT (15%):', 'Penalty Fee',
    'Income Tax Fee', 'Tax', 'Interest Fee', 'Stamp Duty', 'Discount Amount',
    'Total',
  ];
  final v = _sliceLabels(text, labels);

  double? amount;
  final amountRaw = v['Transaction Amount'];
  if (amountRaw != null) {
    final m = RegExp(r'ETB\s*([0-9,]+\.\d{2})').firstMatch(amountRaw);
    if (m != null) amount = double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  String? date;
  final dateRaw = v['Transaction Date:'];
  if (dateRaw != null) {
    final m = RegExp(
            r'[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4},?\s+\d{1,2}:\d{2}:\d{2}\s*(?:am|pm)?',
            caseSensitive: false)
        .firstMatch(dateRaw);
    date = m?[0] ?? dateRaw;
  }

  final sender = v['Sender Name:'];
  final receiver = v['Receiver Name:'];
  final reference = v['Transaction Reference:'];
  if (sender == null || receiver == null || amount == null || reference == null) {
    return Parsed.notFound;
  }

  return Parsed(
    verified: true,
    senderName: sender,
    senderAccount: v['Sender Account Number:'],
    receiverName: receiver,
    receiverAccount: v['Receiver Account Number:'],
    amount: amount,
    date: date,
    reference: reference,
    reason: v['Narrative:'],
  );
}

Parsed parseZemenPdfText(String text) {
  if (text.isEmpty || (!text.contains('Zemen') && !text.contains('ETTB'))) {
    return Parsed.notFound;
  }

  const labels = [
    'Transaction Reference:', 'Transaction Date:', 'Transaction Amount:',
    'Service Charge', 'VAT', 'Total Amount', 'Sender Name:', 'Sender Account:',
    'Receiver Name:', 'Receiver Account:', 'Receiver Bank:', 'Narrative:',
    'Payment Reason:', 'Status:', 'Currency:',
  ];
  final v = _sliceLabels(text, labels);

  double? amount;
  final amountRaw = v['Transaction Amount:'] ?? v['Total Amount'];
  if (amountRaw != null) {
    final m = RegExp(r'(?:ETB\s*)?([0-9,]+\.\d{2})').firstMatch(amountRaw);
    if (m != null) amount = double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  final sender = v['Sender Name:'];
  final receiver = v['Receiver Name:'];
  final reference = v['Transaction Reference:'];
  if ((sender == null && receiver == null) ||
      amount == null ||
      (reference == null && !text.contains('ETTB'))) {
    return Parsed.notFound;
  }

  return Parsed(
    verified: true,
    senderName: sender,
    senderAccount: v['Sender Account:'],
    receiverName: receiver,
    receiverAccount: v['Receiver Account:'],
    amount: amount,
    currency: v['Currency:'] ?? 'ETB',
    date: v['Transaction Date:'],
    reference: reference,
    reason: v['Narrative:'] ?? v['Payment Reason:'],
    transactionStatus: v['Status:'],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// CBE Birr, Siinqee & eBirr — generic key/value HTML receipts.
// ─────────────────────────────────────────────────────────────────────────────

String _kvStripHtml(String html) {
  return html
      .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</td>\s*<td[^>]*>', caseSensitive: false), ':\t')
      .replaceAll(RegExp(r'</tr>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n[ \t]*\n'), '\n')
      .trim();
}

Map<String, String> _kvExtractFields(String text) {
  final fields = <String, String>{};
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final colon = RegExp(r'^([^:]+):\s*(.+)$').firstMatch(line);
    if (colon != null) {
      final key = colon.group(1)!.trim().toLowerCase();
      final value = colon.group(2)!.trim();
      if (value.isNotEmpty) fields.putIfAbsent(key, () => value);
      continue;
    }
    final tab = RegExp(r'^([^\t]+)\t(.+)$').firstMatch(line);
    if (tab != null) {
      final key = tab.group(1)!.trim().toLowerCase();
      final value = tab.group(2)!.trim();
      if (value.isNotEmpty) fields.putIfAbsent(key, () => value);
    }
  }
  return fields;
}

Parsed parseCbeBirrHtml(String html) {
  if (html.length < 500) return Parsed.notFound;
  final text = _kvStripHtml(html);
  if (text.contains('No receipt found') ||
      text.contains('Invalid transaction') ||
      text.toLowerCase().contains('not found')) {
    return Parsed.notFound;
  }
  final f = _kvExtractFields(text);

  final senderName = f['sender name'] ?? f['payer name'] ?? f['sender'] ?? f['payer'];
  final receiverName =
      f['receiver name'] ?? f['beneficiary name'] ?? f['receiver'] ?? f['beneficiary'];
  final amountRaw = f['amount'] ?? f['transaction amount'] ?? f['transferred amount'];
  final amount = amountRaw == null ? null : _parseAmount(amountRaw);
  final status = f['status'] ?? f['transaction status'];

  if (senderName == null && receiverName == null && amount == null) {
    return Parsed.notFound;
  }
  return Parsed(
    verified: true,
    senderName: senderName,
    receiverName: receiverName,
    senderAccount:
        f['sender account'] ?? f['payer account'] ?? f['from account'],
    receiverAccount: f['receiver account'] ?? f['beneficiary account'] ?? f['to account'],
    amount: amount,
    date: f['date'] ?? f['transaction date'] ?? f['time'],
    reference:
        f['reference'] ?? f['transaction id'] ?? f['transaction reference'] ?? f['receipt no'],
    transactionStatus: status,
  );
}

const Map<String, String> _ebirrTenants = {
  'nib': 'Nib International Bank',
  'wegagen': 'Wegagen Bank',
  'ahadu': 'Ahadu Bank',
  'kaafimf': 'KAAFI Microfinance',
  'coop': 'Cooperative Bank of Oromia',
  'siinqee': 'Siinqee Bank',
};

Parsed parseEbirrHtml(String html) {
  if (html.contains('Not Found Page') || html.contains('color: red')) {
    return Parsed.notFound;
  }
  final text = _kvStripHtml(html);
  if (text.length < 20) return Parsed.notFound;
  final f = _kvExtractFields(text);

  final senderName = f['sender'] ?? f['payer'] ?? f['from'] ?? f['sender name'] ?? f['payer name'];
  final receiverName =
      f['receiver'] ?? f['payee'] ?? f['to'] ?? f['receiver name'] ?? f['beneficiary'];
  final amountRaw = f['amount'] ?? f['transferred amount'] ?? f['transfer amount'];
  final amount = amountRaw == null ? null : _parseAmount(amountRaw);
  final status = f['status'] ?? f['transaction status'];
  final phone = f['phone'] ?? f['mobile'] ?? f['phone number'];

  if (senderName == null && receiverName == null && amount == null) {
    return Parsed.notFound;
  }

  String? tenantBank;
  final tenant =
      RegExp(r'receipt\.ebirr\.com/([^/]+)', caseSensitive: false).firstMatch(html)?.group(1);
  if (tenant != null) tenantBank = _ebirrTenants[tenant.toLowerCase()];

  return Parsed(
    verified: true,
    senderName: senderName,
    receiverName: receiverName,
    senderAccount: f['sender account'] ?? f['from account'] ?? f['payer account'] ?? phone,
    receiverAccount: f['receiver account'] ?? f['to account'] ?? f['payee account'],
    amount: amount,
    date: f['date'] ?? f['transaction date'] ?? f['time'],
    reference: f['reference'] ?? f['transaction id'] ?? f['ref'] ?? f['transaction reference'],
    transactionStatus: status,
    bankAccountName: tenantBank,
  );
}
