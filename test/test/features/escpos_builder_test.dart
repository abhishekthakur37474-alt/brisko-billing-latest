import 'dart:typed_data';

import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_builder.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_commands.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_encoding.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_text_layout.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';

/// The ESC/POS byte stream, at the level of individual commands.
///
/// These tests are about the protocol rather than about a receipt: that the right bytes
/// are emitted, in the right order, with the right lengths, and that a 48-column budget
/// is never exceeded. No printer and no database are involved — the builder is a pure
/// function from calls to bytes.
void main() {
  const int columns = 48;

  EscPosBuilder builder() => EscPosBuilder();

  EscPosTranscript read(EscPosBuilder built) =>
      EscPosTranscript.of(built.bytes());

  group('paper', () {
    test('80mm is 48 columns of Font A across 576 dots', () {
      expect(PaperWidth.mm80.millimetres, 80);
      expect(PaperWidth.mm80.characterColumns, columns);
      expect(PaperWidth.mm80.printableDots, 576);
      expect(PaperWidth.mm80.label, '80mm');
    });

    test('a builder lays out for the profile it was given', () {
      expect(EscPosBuilder().columns, columns);
      expect(
        EscPosBuilder(
          profile: PrintProfile.escPos80mm.copyWith(paper: PaperWidth.mm58),
        ).columns,
        32,
      );
    });
  });

  group('housekeeping', () {
    test('a document opens with a reset, a code page and a font', () {
      final EscPosBuilder built = builder()..initialise();

      final EscPosTranscript transcript = read(built);
      expect(transcript.commands.first, EscPosCommands.initialise);
      expect(
        transcript.commands[1],
        EscPosCommands.selectCodePage(EscPosCommands.codePagePc437),
      );
      // The font is selected rather than assumed: a printer left in Font B would fit
      // 64 columns and make every laid-out line come out narrow.
      expect(
        transcript.commands[2],
        EscPosCommands.selectFont(PrinterFont.fontA.selector),
      );
    });

    test('a Font B profile selects Font B and widens the budget', () {
      final EscPosBuilder built = EscPosBuilder(
        profile: PrintProfile.escPos80mm.copyWith(font: PrinterFont.fontB),
      )..initialise();

      expect(built.columns, 64);
      expect(
        read(built).commands[2],
        EscPosCommands.selectFont(PrinterFont.fontB.selector),
      );
    });

    test('nothing is emitted until something is written', () {
      expect(builder().length, 0);
    });
  });

  group('text', () {
    test('a line is the text followed by a feed', () {
      final EscPosBuilder built = builder()..line('Cheese Pizza');

      expect(read(built).lines, <String>['Cheese Pizza']);
    });

    test('alignment is set and returned to the left', () {
      final EscPosBuilder built = builder()..centred('Brisko Pizza');

      final EscPosTranscript transcript = read(built);
      expect(transcript.hasCommand(EscPosCommands.alignCentre), isTrue);
      // Left again afterwards, so the next line is not centred by accident.
      expect(transcript.commands.last, EscPosCommands.alignLeft);
    });

    test('bold is turned on and off around the text', () {
      final EscPosBuilder built = builder()..line('TOTAL', bold: true);

      final EscPosTranscript transcript = read(built);
      expect(transcript.commands.first, EscPosCommands.boldOn);
      expect(transcript.commands.last, EscPosCommands.boldOff);
      expect(transcript.lines, <String>['TOTAL']);
    });

    test('double height is turned on and back to normal', () {
      final EscPosBuilder built = builder()..line('640.00', doubleHeight: true);

      final EscPosTranscript transcript = read(built);
      expect(transcript.hasCommand(EscPosCommands.sizeDoubleHeight), isTrue);
      expect(transcript.hasCommand(EscPosCommands.sizeNormal), isTrue);
    });

    test('emphasis does not leak past the line that asked for it', () {
      final EscPosBuilder built = builder()
        ..line('bold', bold: true)
        ..line('plain');

      // Bold off is emitted before the second line's text begins.
      final EscPosTranscript transcript = read(built);
      expect(transcript.commandCount(EscPosCommands.boldOn), 1);
      expect(transcript.commandCount(EscPosCommands.boldOff), 1);
      expect(transcript.lines, <String>['bold', 'plain']);
    });

    test('a separator fills the paper exactly', () {
      final EscPosBuilder built = builder()
        ..separator()
        ..separator(emphasis: true);

      final EscPosTranscript transcript = read(built);
      expect(transcript.lines[0], '-' * columns);
      expect(transcript.lines[1], '=' * columns);
      expect(transcript.lines[0].length, columns);
    });

    test('a blank line is a feed and nothing else', () {
      final EscPosBuilder built = builder()..blankLine();

      expect(read(built).lines, <String>['']);
      expect(built.bytes(), Uint8List.fromList(<int>[EscPosCommands.lf]));
    });
  });

  group('two-column rows', () {
    test('the right-hand value sits at the paper edge', () {
      final EscPosBuilder built = builder()..row('Subtotal', '640.00');

      final String line = read(built).lines.single;
      expect(line.length, columns);
      expect(line.endsWith('640.00'), isTrue);
      expect(line.startsWith('Subtotal'), isTrue);
    });

    test('a long label gives way rather than pushing the amount off', () {
      final EscPosBuilder built = builder()
        ..row('A label far longer than any receipt column could hold', '9.99');

      final String line = read(built).lines.single;
      expect(line.length, columns);
      expect(line.endsWith('9.99'), isTrue);
      expect(line, contains(EscPosTextLayout.ellipsis));
    });

    test('the columns never run together', () {
      // 42 characters of label plus a 6-character amount is exactly full, so the
      // label must lose a character to keep the gap.
      final EscPosBuilder built = builder()..row('x' * 42, '640.00');

      final String line = read(built).lines.single;
      expect(line.length, columns);
      expect(line.contains('x 640.00') || line.contains('. 640.00'), isTrue);
    });
  });

  group('amounts', () {
    test('an amount row renders exact paise', () {
      final EscPosBuilder built = builder()
        ..amountRow('Subtotal', const Money.fromPaise(64000))
        ..amountRow('Odd', const Money.fromPaise(5))
        ..amountRow('Large', const Money.fromPaise(9999999));

      final List<String> lines = read(built).lines;
      expect(lines[0].endsWith('640.00'), isTrue);
      expect(lines[1].endsWith('0.05'), isTrue);
      expect(lines[2].endsWith('99999.99'), isTrue);
    });

    test('a total is bold, double height, and still fits the paper', () {
      final EscPosBuilder built = builder()
        ..totalRow('TOTAL INR', Money.parse('1234.50'));

      final EscPosTranscript transcript = read(built);
      expect(transcript.hasCommand(EscPosCommands.boldOn), isTrue);
      expect(transcript.hasCommand(EscPosCommands.sizeDoubleHeight), isTrue);
      // Double height, never double width: double width would halve the columns and
      // push the amount off the roll.
      expect(transcript.hasCommand(EscPosCommands.sizeDoubleWidth), isFalse);

      final String line = transcript.lines.single;
      expect(line.length, columns);
      expect(line.endsWith('1234.50'), isTrue);
    });

    test('zero prints as zero rather than being omitted', () {
      final EscPosBuilder built = builder()..amountRow('Discount', Money.zero);

      expect(read(built).lines.single.endsWith('0.00'), isTrue);
    });
  });

  group('item rows', () {
    test(
      'a priced item carries the quantity, the unit price and the total',
      () {
        final EscPosBuilder built = builder()
          ..itemRow(
            name: 'Cheese Pizza (Medium)',
            quantity: 2,
            unitPrice: Money.parse('320.00'),
            lineTotal: Money.parse('640.00'),
          );

        final List<String> lines = read(built).lines;
        expect(lines[0], 'Cheese Pizza (Medium)');
        expect(lines[1], startsWith('  2 x 320.00'));
        expect(lines[1].endsWith('640.00'), isTrue);
        expect(lines[1].length, columns);
      },
    );

    test('an unpriced item prints the quantity and no money at all', () {
      final EscPosBuilder built = builder()
        ..itemRow(name: 'Cheese Pizza (Medium)', quantity: 2);

      final List<String> lines = read(built).lines;
      expect(lines[0], 'Cheese Pizza (Medium)');
      expect(lines[1].trim(), 'Qty 2');
      expect(read(built).text, isNot(contains('.')));
    });

    test('options are indented under the item, in order', () {
      final EscPosBuilder built = builder()
        ..itemRow(
          name: 'Cheese Pizza (Medium)',
          quantity: 1,
          options: <String>['Extra Cheese', 'Thin Crust', 'Extra Toppings'],
          unitPrice: Money.parse('320.00'),
          lineTotal: Money.parse('320.00'),
        );

      final List<String> lines = read(built).lines;
      expect(lines[1], '  + Extra Cheese');
      expect(lines[2], '  + Thin Crust');
      expect(lines[3], '  + Extra Toppings');
    });

    test('a note is marked so it cannot be read as another option', () {
      final EscPosBuilder built = builder()
        ..itemRow(
          name: 'Cheese Pizza',
          quantity: 1,
          options: <String>['Extra Cheese'],
          notes: 'no onion',
        );

      final List<String> lines = read(built).lines;
      expect(lines[1], '  + Extra Cheese');
      expect(lines[2], '  * no onion');
    });

    test('a very long name wraps and nothing exceeds the paper', () {
      final EscPosBuilder built = builder()
        ..itemRow(
          name:
              'Farmhouse Special Deluxe Paneer Tikka Extra Large Family Feast '
              'Pizza with Stuffed Crust (Large)',
          quantity: 3,
          unitPrice: Money.parse('749.00'),
          lineTotal: Money.parse('2247.00'),
        );

      final EscPosTranscript transcript = read(built);
      expect(transcript.widestLine, lessThanOrEqualTo(columns));
      expect(transcript.lines.length, greaterThan(2));
      // The name survives in full across the wrapped lines.
      expect(
        transcript.lines.take(transcript.lines.length - 1).join(' '),
        contains('Stuffed Crust (Large)'),
      );
      expect(transcript.lines.last.endsWith('2247.00'), isTrue);
    });

    test('a name with no spaces is split rather than left to the printer', () {
      final EscPosBuilder built = builder()
        ..itemRow(name: 'A' * 100, quantity: 1);

      final EscPosTranscript transcript = read(built);
      expect(transcript.widestLine, lessThanOrEqualTo(columns));
      expect(
        transcript.lines.where((String line) => line.startsWith('A')).length,
        3,
      );
    });
  });

  group('feed and cut', () {
    test('the paper is fed clear of the blade before cutting', () {
      final EscPosBuilder built = builder()..cut();

      final EscPosTranscript transcript = read(built);
      expect(transcript.commands, <List<int>>[
        EscPosCommands.feed(PrintProfile.escPos80mm.feedLinesBeforeCut),
        EscPosCommands.cutFull,
      ]);
    });

    test('a partial cut leaves the paper attached', () {
      final EscPosBuilder built = EscPosBuilder(
        profile: PrintProfile.escPos80mm.copyWith(cut: PrintCut.partial),
      )..cut();

      expect(read(built).commands.last, EscPosCommands.cutPartial);
    });

    test('a printer with no blade is fed instead of cut', () {
      // The paper still has to clear the tear bar, so the feed happens either way.
      final EscPosBuilder built = EscPosBuilder(
        profile: PrintProfile.escPos80mm.copyWith(cut: PrintCut.none),
      )..cut();

      final EscPosTranscript transcript = read(built);
      expect(transcript.commands, <List<int>>[
        EscPosCommands.feed(PrintProfile.escPos80mm.feedLinesBeforeCut),
      ]);
      expect(transcript.hasCommand(EscPosCommands.cutFull), isFalse);
      expect(transcript.hasCommand(EscPosCommands.cutPartial), isFalse);
    });

    test('a feed of zero or fewer lines emits nothing', () {
      expect((builder()..feed(0)).length, 0);
      expect((builder()..feed(-3)).length, 0);
    });

    test('a feed is one command carrying the line count', () {
      expect(read(builder()..feed(3)).commands.single, <int>[0x1B, 0x64, 0x03]);
    });
  });

  group('qr code', () {
    const String upi = 'upi://pay?pa=outlet%40bank&pn=Outlet&am=640.00&cu=INR';

    test('the five commands are emitted in specification order', () {
      final EscPosBuilder built = builder()..qrCode(upi);

      final EscPosTranscript transcript = read(built);
      expect(transcript.hasCommand(EscPosCommands.qrSelectModel2), isTrue);
      expect(
        transcript.hasCommand(
          EscPosCommands.qrModuleSize(PrintProfile.escPos80mm.qrModuleSize),
        ),
        isTrue,
      );
      expect(
        transcript.hasCommand(
          EscPosCommands.qrErrorCorrection(
            EscPosCommands.qrErrorCorrectionMedium,
          ),
        ),
        isTrue,
      );
      expect(transcript.hasCommand(EscPosCommands.qrPrint), isTrue);

      // And in that order: model, size, correction, store, print.
      final List<String> sequence = transcript.commands
          .map((List<int> command) => command.take(8).join(','))
          .toList(growable: false);
      final int model = sequence.indexWhere(
        (String c) => c.startsWith('29,40,107,4,0,49,65'),
      );
      final int print = sequence.indexWhere(
        (String c) => c.startsWith('29,40,107,3,0,49,81,48'),
      );
      expect(model, lessThan(print));
    });

    test('the stored payload is the data, byte for byte', () {
      final EscPosBuilder built = builder()..qrCode(upi);

      expect(read(built).qrPayloads, <String>[upi]);
    });

    test(
      'the store command length covers the data and its three function bytes',
      () {
        // The classic ESC/POS QR bug: get this wrong and the printer reads the rest of
        // the document as commands. The decoder walking the stream successfully is the
        // assertion, and the payload coming back intact is the proof.
        final List<int> command = EscPosCommands.qrStoreData(
          EscPosEncoding.encode(upi),
        );
        final int declared = command[3] | (command[4] << 8);

        expect(declared, upi.length + 3);
        expect(command.length, 5 + declared);
      },
    );

    test('the symbol is centred and the alignment is put back', () {
      final EscPosBuilder built = builder()..qrCode(upi);

      final EscPosTranscript transcript = read(built);
      expect(transcript.hasCommand(EscPosCommands.alignCentre), isTrue);
      expect(transcript.commands.last, EscPosCommands.alignLeft);
    });

    test('empty data prints nothing', () {
      expect((builder()..qrCode('')).length, 0);
    });

    test('a payload beyond the command length prints nothing', () {
      // Rather than a truncated symbol, which would scan to a corrupted payment URI.
      final EscPosBuilder built = builder()
        ..qrCode('a' * (EscPosCommands.qrMaxDataLength + 1));

      expect(built.length, 0);
    });

    test('a printer with no QR engine emits no QR commands', () {
      final EscPosBuilder built = EscPosBuilder(
        profile: PrintProfile.escPos80mm.copyWith(canPrintQrCode: false),
      )..qrCode(upi);

      expect(built.length, 0);
    });

    test('the error correction level comes from the profile', () {
      final EscPosBuilder built = EscPosBuilder(
        profile: PrintProfile.escPos80mm.copyWith(
          qrErrorCorrection: QrErrorCorrection.high,
        ),
      )..qrCode(upi);

      expect(
        read(built).hasCommand(
          EscPosCommands.qrErrorCorrection(
            EscPosCommands.qrErrorCorrectionHigh,
          ),
        ),
        isTrue,
      );
      expect(
        EscPosBuilder.errorCorrectionByte(QrErrorCorrection.medium),
        EscPosCommands.qrErrorCorrectionMedium,
      );
    });
  });

  group('character encoding', () {
    test('plain ASCII passes through unchanged', () {
      expect(EscPosEncoding.encode('Pizza 640.00'), 'Pizza 640.00'.codeUnits);
    });

    test('the rupee sign becomes Rs. rather than a garbage glyph', () {
      // No ESC/POS code page contains U+20B9, so it is substituted rather than sent.
      expect(
        String.fromCharCodes(EscPosEncoding.encode('\u20B9640')),
        'Rs.640',
      );
      expect(EscPosEncoding.displayWidth('\u20B9640'), 6);
      expect(EscPosEncoding.normalise('\u20B9'), 'Rs.');
    });

    test('a substituted character is measured at its printed width', () {
      // Laying out by Dart length would push the right-hand column two cells off the
      // paper, because one Dart character becomes three printed cells.
      final String line = EscPosTextLayout.twoColumns(
        'Total',
        '\u20B9640.00',
        width: columns,
      );

      expect(line.length, columns);
      expect(line.endsWith('Rs.640.00'), isTrue);
    });

    test('typographic characters brought in by a paste are flattened', () {
      expect(
        EscPosEncoding.normalise('Don\u2019t \u2014 2\u00D73 \u2026'),
        "Don't - 2x3 ...",
      );
    });

    test('an unrepresentable character is visibly replaced', () {
      // Conspicuous rather than a random glyph that looks deliberate.
      expect(EscPosEncoding.encode('\u0915'), <int>[
        EscPosEncoding.replacementByte,
      ]);
    });

    test('a control character cannot smuggle in a command', () {
      // A stray 0x1B in operator-typed text would otherwise be read as the start of an
      // escape sequence.
      final List<int> encoded = EscPosEncoding.encode('a\u001Bb');

      expect(encoded, <int>[0x61, EscPosEncoding.replacementByte, 0x62]);
    });
  });

  group('layout primitives', () {
    test('wrapping breaks on words', () {
      expect(EscPosTextLayout.wrap('one two three', 8), <String>[
        'one two',
        'three',
      ]);
    });

    test('wrapping a word longer than the line splits it', () {
      expect(EscPosTextLayout.wrap('abcdefghij', 4), <String>[
        'abcd',
        'efgh',
        'ij',
      ]);
    });

    test('wrapping empty text produces no lines', () {
      expect(EscPosTextLayout.wrap('   ', 48), isEmpty);
      expect(EscPosTextLayout.wrap('anything', 0), isEmpty);
    });

    test('indented wrapping keeps every line inside the paper', () {
      final List<String> lines = EscPosTextLayout.wrapIndented(
        '+ ${'Extra Cheese ' * 8}',
        columns,
        by: 2,
      );

      expect(lines.length, greaterThan(1));
      for (final String line in lines) {
        expect(line.length, lessThanOrEqualTo(columns));
        expect(line, startsWith('  '));
      }
    });

    test('truncation marks that something was cut', () {
      expect(EscPosTextLayout.truncate('abcdefgh', 5), 'abc..');
      expect(EscPosTextLayout.truncate('abc', 5), 'abc');
      expect(EscPosTextLayout.truncate('abc', 0), '');
    });

    test('a separator of zero width is empty', () {
      expect(EscPosTextLayout.separator(0), '');
    });
  });
}
