/// Turns document text into the single-byte characters an ESC/POS printer prints.
///
/// ## The problem
///
/// A thermal printer has no Unicode. It holds a handful of 256-entry code pages and
/// prints one byte per character. Sending UTF-8 to one produces two or three garbage
/// glyphs for every non-ASCII character, and sending a code point it has no glyph for
/// produces whatever happens to sit at that byte.
///
/// ## The rupee sign
///
/// No standard ESC/POS code page contains U+20B9. Printing the ₹ glyph on this class
/// of hardware needs either a printer with an Indian code page loaded or the symbol
/// rasterised as a bitmap, and which of the two applies cannot be established without
/// the printer in hand.
///
/// So the layout does not put ₹ into the amount columns at all: amounts print as
/// digits, and the totals block is labelled INR once. Where a rupee sign does reach
/// this encoder — most likely inside a header or footer the operator typed into
/// settings — it is substituted with `Rs.` rather than dropped, which is what an
/// Indian receipt printed on this hardware has always looked like.
///
/// [substitutions] holds that mapping and a short list of the other characters a
/// pasted string brings with it: smart quotes, dashes and the multiplication sign.
/// Anything still unrepresentable becomes `?`, which is visible and obviously wrong,
/// rather than a random glyph that looks deliberate.
class EscPosEncoding {
  const EscPosEncoding._();

  /// Byte printed for a character with no representation. Chosen to be conspicuous.
  static const int replacementByte = 0x3F; // '?'

  /// Code points replaced by an ASCII equivalent before encoding.
  ///
  /// Kept small and explicit. A general transliteration library would be the wrong
  /// answer: this is a fixed set of characters that turn up in operator-typed text
  /// and in the application's own strings.
  static const Map<int, String> substitutions = <int, String>{
    0x20B9: 'Rs.', // ₹ rupee sign
    0x00D7: 'x', // × multiplication sign
    0x2018: "'", // ‘ left single quote
    0x2019: "'", // ’ right single quote
    0x201C: '"', // “ left double quote
    0x201D: '"', // ” right double quote
    0x2013: '-', // – en dash
    0x2014: '-', // — em dash
    0x2026: '...', // … ellipsis
    0x00A0: ' ', // non-breaking space
  };

  /// Encodes [text] to printable bytes.
  ///
  /// Substitutions are applied first, so a rupee sign becomes three ASCII bytes and
  /// the caller's column arithmetic — which runs on [displayWidth] — agrees with what
  /// the printer will actually put on the paper.
  static List<int> encode(String text) {
    final List<int> bytes = <int>[];
    for (final int rune in text.runes) {
      final String? substitute = substitutions[rune];
      if (substitute != null) {
        bytes.addAll(substitute.codeUnits);
        continue;
      }
      // Printable ASCII, plus the space. Control characters are dropped rather than
      // passed through, because a stray 0x1B in operator-typed text would be read as
      // the start of a command.
      if (rune >= 0x20 && rune <= 0x7E) {
        bytes.add(rune);
        continue;
      }
      if (rune == 0x0A) {
        bytes.add(rune);
        continue;
      }
      bytes.add(replacementByte);
    }
    return bytes;
  }

  /// How many character cells [text] will occupy once encoded.
  ///
  /// This is the number the layout must use, not `String.length`. A rupee sign is one
  /// Dart character and three printed cells, so laying out a line by its Dart length
  /// would push the right-hand column two characters off the paper.
  static int displayWidth(String text) {
    int width = 0;
    for (final int rune in text.runes) {
      final String? substitute = substitutions[rune];
      width += substitute?.length ?? 1;
    }
    return width;
  }

  /// Applies the substitutions without encoding, for laying out a line.
  static String normalise(String text) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in text.runes) {
      final String? substitute = substitutions[rune];
      if (substitute != null) {
        buffer.write(substitute);
      } else if (rune >= 0x20 && rune <= 0x7E) {
        buffer.writeCharCode(rune);
      } else {
        buffer.writeCharCode(replacementByte);
      }
    }
    return buffer.toString();
  }
}
