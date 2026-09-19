import 'dart:convert';

/// Receipt verifier — data model and bank catalog.
///
/// Dart port of the core of 1RB/cheki (MIT): verify Ethiopian bank and
/// mobile-money transfer receipts by calling each provider's own public
/// receipt endpoint and parsing the response. The shop uses it to confirm
/// a customer's transfer before handing over the goods.

/// One supported bank / wallet and what input it needs.
class BankInfo {
  final String id;
  final String name;
  final String shortName;
  final bool isWallet;

  /// Extra receiving-account digits required by some banks (CBE legacy needed
  /// 8; BOA needs the last 5; the new CBE link/QR flow needs none).
  final int accountDigits;
  final String accountLabel;
  final bool requiresPhone;

  /// Label / placeholder / helper for the main reference input.
  final String referenceLabel;
  final String referenceHint;
  final String helper;

  /// Some bank endpoints have broken TLS certificates (Awash, CBE) — the
  /// IO client relaxes verification for exactly those hosts.
  final bool allowBadCertificate;

  /// True when the provider blocks requests coming from outside Ethiopia
  /// (fine for the app's real users; only matters for VPN users).
  final bool geoBlocked;

  const BankInfo({
    required this.id,
    required this.name,
    required this.shortName,
    required this.isWallet,
    this.accountDigits = 0,
    this.accountLabel = 'Account (last digits)',
    this.requiresPhone = false,
    required this.referenceLabel,
    required this.referenceHint,
    required this.helper,
    this.allowBadCertificate = false,
    this.geoBlocked = false,
  });

  String get initials {
    final words = shortName.trim().split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return (words[0][0] + words[1][0]).toUpperCase();
    }
    return shortName.substring(0, shortName.length.clamp(1, 2)).toUpperCase();
  }
}

/// The live catalog, ordered by how often Ethiopian shops see them at the
/// till (Telebirr and CBE first).
const List<BankInfo> kVerifyBanks = [
  BankInfo(
    id: 'telebirr',
    name: 'Telebirr',
    shortName: 'Telebirr',
    isWallet: true,
    geoBlocked: true,
    referenceLabel: 'Receipt / invoice number',
    referenceHint: 'e.g. CHQ261Z4AB2C or the full receipt link',
    helper:
        'Copy the receipt number from the Telebirr SMS or app, or paste the '
        'transactioninfo.ethiotelecom.et link.',
  ),
  BankInfo(
    id: 'cbe',
    name: 'Commercial Bank of Ethiopia',
    shortName: 'CBE',
    isWallet: false,
    referenceLabel: 'Receipt link or short code',
    referenceHint: 'Paste the mbreciept.cbe.com.et/… link or the code under the QR',
    helper:
        'Ask the sender for the receipt link or let them show the QR in the '
        'CBE app — scanning it fills this in automatically.',
  ),
  BankInfo(
    id: 'boa',
    name: 'Bank of Abyssinia',
    shortName: 'BOA',
    isWallet: false,
    accountDigits: 5,
    accountLabel: 'Your account number (last 5 digits)',
    referenceLabel: 'Transaction reference',
    referenceHint: 'e.g. FT26140P01YB',
    helper:
        'Reference plus the last 5 digits of the receiving account — or scan '
        'the QR on the BOA slip to verify instantly without them.',
  ),
  BankInfo(
    id: 'mpesa',
    name: 'M-Pesa Ethiopia',
    shortName: 'M-Pesa',
    isWallet: true,
    geoBlocked: true,
    referenceLabel: 'Transaction number',
    referenceHint: 'e.g. SJ72HK3YZ9',
    helper: 'Copy the transaction number from the M-Pesa confirmation SMS.',
  ),
  BankInfo(
    id: 'dashen',
    name: 'Dashen Bank',
    shortName: 'Dashen',
    isWallet: false,
    referenceLabel: 'Transaction reference',
    referenceHint: 'e.g. 26010805472123',
    helper:
        'The reference from the Dashen SuperApp receipt — the bank returns a '
        'PDF receipt which we read and check.',
  ),
  BankInfo(
    id: 'awash',
    name: 'Awash Bank',
    shortName: 'Awash',
    isWallet: false,
    referenceLabel: 'Receipt share link',
    referenceHint: 'Paste the awashpay.awashbank.com:8225/… link from the SMS',
    helper:
        'The sender taps “Share” on their Awash receipt and sends the link — '
        'the numeric transaction ID alone will not work.',
  ),
  BankInfo(
    id: 'zemen',
    name: 'Zemen Bank',
    shortName: 'Zemen',
    isWallet: false,
    referenceLabel: 'Transaction reference',
    referenceHint: 'e.g. ETTB123456789',
    helper: 'The reference from the Zemen share link or receipt PDF.',
  ),
  BankInfo(
    id: 'cbebirr',
    name: 'CBE Birr',
    shortName: 'CBE Birr',
    isWallet: true,
    requiresPhone: true,
    referenceLabel: 'Transaction reference (TID)',
    referenceHint: 'e.g. FT26140P01YB',
    helper: 'The TID from the CBE Birr receipt plus the payer phone number.',
  ),
  BankInfo(
    id: 'siinqee',
    name: 'Siinqee Bank',
    shortName: 'Siinqee',
    isWallet: false,
    referenceLabel: 'Receipt link or token',
    referenceHint: 'Paste the receipt.ebirr.com/siinqee/… link',
    helper: 'Siinqee receipts are served through the eBirr platform.',
  ),
  BankInfo(
    id: 'ebirr',
    name: 'eBirr (Nib, Wegagen, Ahadu…)',
    shortName: 'eBirr',
    isWallet: true,
    referenceLabel: 'Receipt link',
    referenceHint: 'Paste the full receipt.ebirr.com/{bank}/… link',
    helper:
        'Works for receipts shared via receipt.ebirr.com — Nib, Wegagen, '
        'Ahadu, KAAFI and others.',
  ),
];

BankInfo? bankById(String id) {
  for (final b in kVerifyBanks) {
    if (b.id == id) return b;
  }
  return null;
}

/// What a successful verification looks like — the fields shops actually
/// compare against what the customer claims.
class ReceiptData {
  final bool verified;
  final String bankCode;
  final String bankName;
  final String reference;
  final String? senderName;
  final String? senderAccount;
  final String? receiverName;
  final String? receiverAccount;
  final double? amount;
  final String currency;
  final String? date;
  final String? branch;
  final String? reason;
  final String? transactionType;
  final String? transactionStatus;
  final String? invoiceNumber;
  final String? bankAccountNumber;
  final String? bankAccountName;

  /// Advisory note shown with the result (e.g. BOA QR forgery warning).
  final String? note;
  final bool fromQr;

  const ReceiptData({
    required this.verified,
    required this.bankCode,
    required this.bankName,
    required this.reference,
    this.senderName,
    this.senderAccount,
    this.receiverName,
    this.receiverAccount,
    this.amount,
    this.currency = 'ETB',
    this.date,
    this.branch,
    this.reason,
    this.transactionType,
    this.transactionStatus,
    this.invoiceNumber,
    this.bankAccountNumber,
    this.bankAccountName,
    this.note,
    this.fromQr = false,
  });
}

/// Why a verification failed, with copy ready for the UI.
enum VerifyErrorKind { network, notFound, badInput, unreadable, unsupported }

class VerifyFailure {
  final VerifyErrorKind kind;
  final String message;
  final List<String> tips;
  const VerifyFailure(this.kind, this.message, {this.tips = const []});
}

/// One row in the local verification history.
class CheckRecord {
  final int? id;
  final String bank;
  final String bankName;
  final String reference;
  final String status; // 'verified' | 'match' | 'mismatch' | 'failed'
  final double? expectedAmount;
  final double? amount;
  final String? senderName;
  final String? receiverName;
  final String? receiptDate;
  final String? detail;
  final String checkedBy;
  final int checkedAt;

  const CheckRecord({
    this.id,
    required this.bank,
    required this.bankName,
    required this.reference,
    required this.status,
    this.expectedAmount,
    this.amount,
    this.senderName,
    this.receiverName,
    this.receiptDate,
    this.detail,
    required this.checkedBy,
    required this.checkedAt,
  });

  Map<String, Object?> toRow() => {
        'bank': bank,
        'bank_name': bankName,
        'reference': reference,
        'status': status,
        'expected_amount': expectedAmount,
        'amount': amount,
        'sender_name': senderName,
        'receiver_name': receiverName,
        'receipt_date': receiptDate,
        'detail': detail,
        'checked_by': checkedBy,
        'checked_at': checkedAt,
      };

  factory CheckRecord.fromRow(Map<String, Object?> row) => CheckRecord(
        id: row['id'] as int?,
        bank: (row['bank'] ?? '') as String,
        bankName: (row['bank_name'] ?? '') as String,
        reference: (row['reference'] ?? '') as String,
        status: (row['status'] ?? 'failed') as String,
        expectedAmount: (row['expected_amount'] as num?)?.toDouble(),
        amount: (row['amount'] as num?)?.toDouble(),
        senderName: row['sender_name'] as String?,
        receiverName: row['receiver_name'] as String?,
        receiptDate: row['receipt_date'] as String?,
        detail: row['detail'] as String?,
        checkedBy: (row['checked_by'] ?? '') as String,
        checkedAt: (row['checked_at'] ?? 0) as int,
      );

  /// Compact JSON of the fields worth remembering for dispute follow-ups.
  static String detailJson(ReceiptData r) => jsonEncode({
        'sender': r.senderName,
        'senderAccount': r.senderAccount,
        'receiver': r.receiverName,
        'receiverAccount': r.receiverAccount,
        'date': r.date,
        'status': r.transactionStatus,
        'reason': r.reason,
        if (r.note != null) 'note': r.note,
      });
}

/// Everything the verifier needs for one attempt.
class VerifyInput {
  final String bankId;
  final String reference;
  final String? account;
  final String? phone;
  final String? qrData;

  /// When set, the verifier compares the receipt amount against it and the
  /// UI shows a MATCH / MISMATCH verdict.
  final double? expectedAmount;

  const VerifyInput({
    required this.bankId,
    required this.reference,
    this.account,
    this.phone,
    this.qrData,
    this.expectedAmount,
  });
}
