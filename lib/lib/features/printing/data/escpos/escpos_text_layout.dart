import 'escpos_encoding.dart';

/// Fixed-width line layout for a thermal document.
///
/// ## Why the layout is characters, not pixels
///
/// A receipt printer prints a line of monospaced characters. There are no proportional
/// fonts, no measured text and no reflow: a line either fits in the column budget or
/// the printer wraps it wherever it runs out, usually mid-word and usually through the
/// amount. Every method here therefore takes the width in characters and guarantees a
/// result that is at most that wide.
///
/// ## Widths are measured after substitution
///
/// Every width here is [EscPosEncoding.displayWidth], not `String.length`, so a
/// character that encodes to more than one printed cell is accounted for before the
/// line is padded. This is the whole reason this class and the encoder are separate
/// from the byte builder.
///
/// Pure string functions with no state, so the layout of a receipt can be reasoned
/// about, and tested, without a printer or a byte stream anywhere in sight.
class EscPosTextLayout {
  const EscPosTextLayout._();

  /// Marker appended when a single word is too long to break, for example a very
  /// long product name typed without spaces.
  static const String ellipsis = '..';

  /// A full-width rule, for example `------------------------------------------`.
  static String separator(int width, {String character = '-'}) {
    if (width <= 0 || character.isEmpty) {
      return '';
    }
    return character[0] * width;
  }

  /// [left] at the start of the line and [right] at the end, in one line of [width].
  ///
  /// This is the workhorse: a label with an amount, a date with an order type, a
  /// quantity with a line total. The right-hand value is never truncated — an amount
  /// missing its last digit is worse than a clipped label — so when the two cannot
  /// both fit, the left-hand text gives way.
  static String twoColumns(String left, String right, {required int width}) {
    final String rightValue = EscPosEncoding.normalise(right);
    final int rightWidth = EscPosEncoding.displayWidth(rightValue);

    if (rightWidth >= width) {
      return truncate(rightValue, width);
    }

    // One space minimum between the columns, so they never read as one word.
    final int leftBudget = width - rightWidth - 1;
    final String leftValue = truncate(left, leftBudget);
    final int gap = width - EscPosEncoding.displayWidth(leftValue) - rightWidth;

    return '$leftValue${' ' * gap}$rightValue';
  }

  /// [text] broken into lines of at most [width], on word boundaries where possible.
  ///
  /// A word longer than the whole line — which a run-together product name can be —
  /// is hard-split rather than left to the printer, because the printer would break it
  /// at the paper edge and lose the rest of the line's layout.
  static List<String> wrap(String text, int width) {
    if (width <= 0) {
      return const <String>[];
    }

    final String value = EscPosEncoding.normalise(text).trim();
    if (value.isEmpty) {
      return const <String>[];
    }
    if (value.length <= width) {
      return <String>[value];
    }

    final List<String> lines = <String>[];
    final StringBuffer current = StringBuffer();

    for (final String word in value.split(RegExp(r'\s+'))) {
      String remaining = word;

      // A word that cannot fit on a line of its own is split across lines.
      while (remaining.length > width) {
        if (current.isNotEmpty) {
          lines.add(current.toString());
          current.clear();
        }
        lines.add(remaining.substring(0, width));
        remaining = remaining.substring(width);
      }

      if (current.isEmpty) {
        current.write(remaining);
      } else if (current.length + 1 + remaining.length <= width) {
        current.write(' ');
        current.write(remaining);
      } else {
        lines.add(current.toString());
        current.clear();
        current.write(remaining);
      }
    }

    if (current.isNotEmpty) {
      lines.add(current.toString());
    }
    return lines;
  }

  /// [text] wrapped to [width], with every line after the first indented by [by]
  /// spaces.
  ///
  /// Used for a line's options and notes, so a customisation reads as belonging to the
  /// item above it rather than as another item.
  static List<String> wrapIndented(String text, int width, {required int by}) {
    final int inner = width - by;
    if (inner <= 0) {
      return wrap(text, width);
    }
    final String prefix = ' ' * by;
    return wrap(
      text,
      inner,
    ).map((String line) => '$prefix$line').toList(growable: false);
  }

  /// [text] cut to [width] printed cells, ending in [ellipsis] when cut.
  ///
  /// Truncation is a last resort, used only where wrapping is not available, such as
  /// the left column of a two-column row.
  static String truncate(String text, int width) {
    final String value = EscPosEncoding.normalise(text);
    if (width <= 0) {
      return '';
    }
    if (value.length <= width) {
      return value;
    }
    if (width <= ellipsis.length) {
      return value.substring(0, width);
    }
    return '${value.substring(0, width - ellipsis.length)}$ellipsis';
  }
}
