import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pointycastle/export.dart';

import 'package:stylepos/services/receipt_verify/models.dart';
import 'package:stylepos/services/receipt_verify/parsers.dart';
import 'package:stylepos/services/receipt_verify/pdf_text.dart';
import 'package:stylepos/services/receipt_verify/verifier.dart';

void main() {
  group('URL detection', () {
    test('CBE new mbreciept link', () {
      final d = detectBankFromUrl('https://mbreciept.cbe.com.et/fHCx8QmLpZ1');
      expect(d, isNotNull);
      expect(d!.bank, 'cbe');
      expect(d.reference, 'fHCx8QmLpZ1');
    });

    test('CBE legacy apps link maps to cbe-legacy with account suffix', () {
      final d = detectBankFromUrl(
          'https://apps.cbe.com.et:100/?id=FT26140P01YB60536171');
      expect(d, isNotNull);
      expect(d!.bank, 'cbe-legacy');
      expect(d.reference, 'FT26140P01YB');
      expect(d.account, '60536171');
    });

    test('Telebirr receipt link', () {
      final d = detectBankFromUrl(
          'https://transactioninfo.ethiotelecom.et/receipt/CHQ261Z4AB2C');
      expect(d!.bank, 'telebirr');
      expect(d.reference, 'CHQ261Z4AB2C');
    });

    test('Awash share link strips dash and punctuation', () {
      final d = detectBankFromUrl(
          'https://awashpay.awashbank.com:8225/-2KDL95Z0NR-4U61O6.');
      expect(d!.bank, 'awash');
      expect(d.reference, '2KDL95Z0NR-4U61O6');
    });

    test('Zemen rt link', () {
      final d = detectBankFromUrl(
          'https://share.zemenbank.com/rt/ETTB123456789/pdf');
      expect(d!.bank, 'zemen');
      expect(d.reference, 'ETTB123456789');
    });

    test('BOA slip link with trx param', () {
      final d = detectBankFromUrl(
          'https://cs.bankofabyssinia.com/slip/?trx=FT25001ABC');
      expect(d!.bank, 'boa');
      expect(d.reference, 'FT25001ABC');
    });

    test('eBirr tenant link', () {
      final d = detectBankFromUrl(
          'https://receipt.ebirr.com/nib/abc123def');
      expect(d!.bank, 'ebirr');
      expect(d.reference, 'nib/abc123def');
    });

    test('non-bank URL returns null', () {
      expect(
          detectBankFromUrl('https://example.com/receipt/123'), isNull);
    });
  });

  group('CBE new JSON', () {
    const body = '''
    {"id":"fHCx8QmLpZ1","debitAccountHolder":"Mr Mohammed A Reshid",
     "debitAccountNo":"1********1234","creditAccountHolder":"SAMI SHOP PLC",
     "creditAccountNo":"1********8348","amountCredited":"2450.00",
     "creditCurrency":"ETB","dateTimes":["2026-09-18 14:22:10"],
     "paymentDetails":["Clothing payment"]}
    ''';
    test('parses fields', () {
      final p = parseCbeNewJson(body);
      expect(p.verified, isTrue);
      expect(p.senderName, 'Mr Mohammed A Reshid');
      expect(p.receiverName, 'SAMI SHOP PLC');
      expect(p.amount, 2450.00);
      expect(p.date, '2026-09-18 14:22:10');
      expect(p.reason, 'Clothing payment');
    });

    test('missing id → not found', () {
      expect(parseCbeNewJson('{"error":"nope"}').verified, isFalse);
    });
  });

  group('BOA JSON', () {
    const body = '''
    {"body":[{"Source Account Name":"ABEBE KEbede",
      "Source Account":"1000****2211","Transferred Amount":"Br 1,500.00",
      "Receiver's Name":"SAMI CLOTHING","Receiver's Account":"1000****8348",
      "currency":"ETB","Transaction Date":"18-09-2026",
      "Transaction Reference":"FT26140P01YB"}]}
    ''';
    test('parses fields', () {
      final p = parseBoaJson(body);
      expect(p.verified, isTrue);
      expect(p.senderName, 'ABEBE KEbede');
      expect(p.amount, 1500.00);
      expect(p.reference, 'FT26140P01YB');
    });

    test('invalid reference marker → not found', () {
      final p =
          parseBoaJson('{"body":[{"Payer\'s Name":"Invalid reference number"}]}');
      expect(p.verified, isFalse);
    });
  });

  group('BOA QR (offline decryption)', () {
    // Round-trip: encrypt a receipt CSV the way BOA's web app does
    // (AES-256-CBC, PBKDF2-SHA1 key, static salt/IV), then decrypt.
    Uint8List encryptBoaQr(String plain) {
      final key = pbkdf2Sha1(
          utf8.encode('ELqVy2g4pGWLUIKSa+1ijwpPy6eDxBFBLBPrJ24v/IA='),
          utf8.encode('salt'),
          10000,
          32);
      final cbc = CBCBlockCipher(AESEngine());
      final padded = PaddedBlockCipherImpl(PKCS7Padding(), cbc);
      padded.init(
        true,
        PaddedBlockCipherParameters(
          ParametersWithIV(
              KeyParameter(key), Uint8List.fromList(utf8.encode('1234567890123456'))),
          null,
        ),
      );
      return padded.process(Uint8List.fromList(utf8.encode(plain)));
    }

    test('decrypts and parses the embedded CSV', () {
      final qr = base64Encode(encryptBoaQr(
          '1000****2211,ABEBE KEbede,1500,FT26140P01YB,18-09-2026 10:11,'
          '1000****8348,SAMI CLOTHING'));
      final p = decryptBoaQr(qr);
      expect(p, isNotNull);
      expect(p!.verified, isTrue);
      expect(p.senderName, 'ABEBE KEbede');
      expect(p.amount, 1500);
      expect(p.reference, 'FT26140P01YB');
      expect(p.receiverName, 'SAMI CLOTHING');
      expect(p.note, isNotNull); // forgery advisory present
    });

    test('garbage payload returns null', () {
      expect(decryptBoaQr(base64Encode(utf8.encode('not a boa qr'))), isNull);
    });

    test('verifier resolves a BOA QR fully offline', () async {
      final qr = base64Encode(encryptBoaQr(
          '1000****2211,ABEBE KEbede,1500,FT26140P01YB,18-09-2026 10:11,'
          '1000****8348,SAMI CLOTHING'));
      final result = await ReceiptVerifier.I.verify(
          VerifyInput(bankId: 'boa', reference: '', qrData: qr));
      expect(result.ok, isTrue);
      expect(result.receipt!.bankCode, 'boa');
      expect(result.receipt!.fromQr, isTrue);
      expect(result.receipt!.amount, 1500);
    });
  });

  group('PBKDF2-HMAC-SHA1 against RFC 6070 vectors', () {
    String hex(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('c=1', () {
      expect(
          hex(pbkdf2Sha1(utf8.encode('password'), utf8.encode('salt'), 1, 20)),
          '0c60c80f961f0e71f3a9b524af6012062fe037a6');
    });

    test('c=4096', () {
      expect(
          hex(pbkdf2Sha1(
              utf8.encode('password'), utf8.encode('salt'), 4096, 20)),
          '4b007901b765489abead49d926f721d065a429c1');
    });
  });

  group('M-Pesa JSON', () {
    test('parses a successful receipt', () {
      final p = parseMpesaJson(
          '{"responseCode":"0","senderName":"HALLELUJAH","receiverName":"SAMI",'
          '"amount":"320.50","currency":"ETB","transactionDate":"2026-09-18",'
          '"transactionId":"SJ72HK3YZ9"}');
      expect(p.verified, isTrue);
      expect(p.amount, 320.50);
      expect(p.reference, 'SJ72HK3YZ9');
    });

    test('error code → not found', () {
      expect(parseMpesaJson('{"responseCode":"1"}').verified, isFalse);
    });
  });

  group('Telebirr HTML', () {
    const html = '''
    <html><head><title>telebirr receipt</title></head><body>
    <table>
      <tr><td>Payer Name</td><td>MOHAMMED A RESHID</td></tr>
      <tr><td>Payer telebirr no</td><td>0712345678</td></tr>
      <tr><td>Credited Party name</td><td>SAMI CLOTHING</td></tr>
      <tr><td>Bank account number</td><td>1000370251685&nbsp;&nbsp;&nbsp;SAMI CLOTHING PLC</td></tr>
      <tr><td>transaction status</td><td>Successful</td></tr>
      <tr><td>Invoice No.</td><td>CHQ261Z4AB2C</td></tr>
      <tr><td>Payment date</td><td>18-09-2026 14:22:10</td></tr>
      <tr><td>Settled Amount</td><td>2,450.00 Birr</td></tr>
      <tr><td>Stamp Duty</td><td>5.00 Birr</td></tr>
      <tr><td>Payment Mode</td><td>Mobile App</td></tr>
      <tr><td>Payment Reason</td><td>Clothes purchase</td></tr>
    </table></body></html>
    ''';

    test('rejects non-receipt pages', () {
      expect(parseTelebirrHtml('<html>error</html>').verified, isFalse);
    });

    test('parses payer, receiver, amount and invoice', () {
      final p = parseTelebirrHtml(html);
      expect(p.verified, isTrue);
      expect(p.senderName, 'MOHAMMED A RESHID');
      expect(p.senderAccount, '0712345678');
      expect(p.receiverName, 'SAMI CLOTHING');
      expect(p.amount, 2450.00);
      expect(p.reference, 'CHQ261Z4AB2C');
      expect(p.date, '18-09-2026 14:22:10');
      expect(p.transactionStatus, 'Successful');
      expect(p.bankAccountNumber, '1000370251685');
      expect(p.note, isNotNull);
    });

    test('mobile Select-All blob is normalized then parsed', () {
      // cheki's documented real-world blob: the value run sits on the
      // "Settled Amount" line as {ref}{date}{amount} Birr — restructured
      // into label/value pairs before parsing.
      final p = parseTelebirrHtml('<html><body>telebirr receipt'
          '<br>Payer NameMOHAMMED A RESHID'
          '<br>Payer telebirr no0712345678'
          '<br>Credited Party nameSAMI CLOTHING'
          '<br>Invoice details<br>Invoice No.'
          '<br>Settled AmountCHQ261Z4ABC18-09-2026 14:22:102450.00 Birr'
          '<br>Stamp Duty5.00 Birr'
          '</body></html>');
      expect(p.verified, isTrue);
      expect(p.reference, 'CHQ261Z4ABC');
      expect(p.amount, 2450.00);
      expect(p.senderName, 'MOHAMMED A RESHID');
    });
  });

  group('Telebirr QR invoice extraction', () {
    test('finds the 8-12 char A-Z0-9 run', () {
      final blob = latin1.encode(
          '\x02\x9f\x00CHQ261Z4AB2C\x01\xffinvoice');
      final hexStr = blob.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final qr = base64Encode(utf8.encode(hexStr));
      expect(extractTelebirrInvoiceFromQr(qr), 'CHQ261Z4AB2C');
    });

    test('non-hex base64 returns null', () {
      final qr = base64Encode(utf8.encode('zzz-not-hex-zzz'));
      expect(extractTelebirrInvoiceFromQr(qr), isNull);
    });
  });

  group('Awash HTML', () {
    const html = '''
    <html><body><table>
      <tr><td>Sender Name</td><td>ABEBE KEBEDE</td></tr>
      <tr><td>Sender Account</td><td>1234567</td></tr>
      <tr><td>Receiver Name</td><td>SAMI CLOTHING</td></tr>
      <tr><td>Receiver Account</td><td>7654321</td></tr>
      <tr><td>Amount</td><td>3,200.00</td></tr>
      <tr><td>Transaction Date</td><td>2026-09-18 10:11:00</td></tr>
      <tr><td>Transaction ID</td><td>987654321</td></tr>
    </table></body></html>
    ''';
    test('parses a full transfer receipt', () {
      final p = parseAwashHtml(html);
      expect(p.verified, isTrue);
      expect(p.senderName, 'ABEBE KEBEDE');
      expect(p.receiverName, 'SAMI CLOTHING');
      expect(p.amount, 3200.00);
      expect(p.reference, '987654321');
    });

    test('invalid receipt page → not found', () {
      expect(parseAwashHtml('<html>Invalid receipt id</html>').verified,
          isFalse);
    });
  });

  group('eBirr HTML', () {
    const html = '''
    <html><body>
    <div>Sender: HALLE TADESSE</div>
    <div>Receiver: SAMI SHOP</div>
    <div>Amount: Br 780.00</div>
    <div>Date: 18-09-2026</div>
    <div>Status: Completed</div>
    </body></html>
    ''';
    test('parses key/value receipt', () {
      final p = parseEbirrHtml(html);
      expect(p.verified, isTrue);
      expect(p.senderName, 'HALLE TADESSE');
      expect(p.receiverName, 'SAMI SHOP');
      expect(p.amount, 780.00);
    });

    test('not-found page rejected', () {
      expect(parseEbirrHtml('<html><h1 style="color: red">Not Found Page</h1></html>')
          .verified, isFalse);
    });
  });

  group('Dashen & Zemen PDF text', () {
    test('Dashen label slicing', () {
      const text = 'Dashen Bank Payment Receipt Sender Name: ABEBE KEBEDE '
          'Sender Account Number: 1234567890 Receiver Name: SAMI CLOTHING '
          'Receiver Account Number: 0987654321 Transaction Reference: '
          '26010805472123 Transaction Date: Sep 18, 2026, 10:11:00 am '
          'Transaction Amount ETB 2,475.00 Narrative: clothes';
      final p = parseDashenPdfText(text);
      expect(p.verified, isTrue);
      expect(p.senderName, 'ABEBE KEBEDE');
      expect(p.receiverName, 'SAMI CLOTHING');
      expect(p.amount, 2475.00);
      expect(p.reference, '26010805472123');
    });

    test('Zemen label slicing', () {
      const text = 'Zemen Bank Transaction Reference: ETTB123456789 '
          'Transaction Date: 2026-09-18 Transaction Amount: ETB 1,000.00 '
          'Sender Name: ABEBE KEBEDE Receiver Name: SAMI CLOTHING Status: '
          'Completed Currency: ETB';
      final p = parseZemenPdfText(text);
      expect(p.verified, isTrue);
      expect(p.amount, 1000.00);
      expect(p.reference, 'ETTB123456789');
      expect(p.transactionStatus, 'Completed');
    });
  });

  group('PDF text extractor', () {
    test('extracts text from a pdf-package generated receipt', () async {
      final doc = pw.Document();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Paragraph(
            text: 'Dashen Bank Payment Receipt Sender Name: ABEBE KEBEDE '
                'Receiver Name: SAMI CLOTHING Transaction Reference: '
                '26010805472123 Transaction Amount ETB 2,475.00'),
      ));
      final bytes = await doc.save();
      final text = extractPdfText(Uint8List.fromList(bytes));
      expect(text, contains('Dashen Bank'));
      expect(text, contains('Sender Name:'));
      expect(text, contains('26010805472123'));

      final parsed = parseDashenPdfText(text);
      expect(parsed.verified, isTrue);
      expect(parsed.amount, 2475.00);
    });
  });
}
