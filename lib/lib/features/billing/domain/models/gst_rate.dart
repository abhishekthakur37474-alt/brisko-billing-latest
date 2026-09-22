/// A GST rate, held as an exact integer count of basis points.
///
/// ## Why basis points
///
/// 10000 basis points is 100%, so 5% is `500` and 18% is `1800`. The rate is an `int`
/// for the same reason every amount in this application is: 18% cannot be represented
/// exactly as a binary fraction, and a rate stored as `0.18` would multiply a subtotal
/// into a figure that is a paisa out. `Money.applyRate` takes basis points and rounds
/// once, half away from zero, which is the only rounding a bill performs.
///
/// Basis points also give two decimal places of rate without any parsing subtlety:
/// 12.5% is `1250`. That is more precision than an Indian restaurant slab needs, and it
/// costs nothing to carry.
///
/// ## Why zero is the default
///
/// An outlet that has not configured a rate is not charging GST, and a bill must never
/// invent a tax line. [zero] is what a freshly installed terminal runs on and what a
/// historical bill reads back as when no rate was recorded against it, so an existing
/// bill is unchanged by this feature arriving.
///
/// ## What this deliberately is not
///
/// There is one combined rate for the whole bill. There is no per-item slab, no HSN
/// code, no place of supply and no IGST: the outlet is a single restaurant serving
/// customers in its own state, and a tax engine it has no use for would be a large
/// amount of code that could only ever be wrong in ways nobody would notice. The
/// CGST/SGST halves on a bill are a presentation of [basisPoints], not a second rate —
/// see `BillTotals.cgst`.
class GstRate implements Comparable<GstRate> {
  /// Creates a rate from an exact count of basis points.
  const GstRate.ofBasisPoints(this.basisPoints);

  /// No GST. What an unconfigured terminal charges, and what a bill settled before this
  /// feature existed is read back as.
  static const GstRate zero = GstRate.ofBasisPoints(0);

  /// Basis points in 100%. A rate above this would take more than the whole bill.
  static const int maxBasisPoints = 10000;

  /// Basis points in one percent.
  static const int basisPointsPerPercent = 100;

  /// The rates offered on the Settings screen, lowest first.
  ///
  /// The four combined slabs an Indian restaurant is put on, plus zero for an outlet
  /// that is not charging GST. Offered as a choice rather than a free-text field because
  /// a rate is picked from a small known set, and a list cannot be mistyped: there is no
  /// way to save 180% by leaving off a decimal point.
  ///
  /// This is not a claim about which slab this outlet is on. Nothing selects a non-zero
  /// entry on the outlet's behalf, and [zero] is first because it is the default.
  static const List<GstRate> selectable = <GstRate>[
    zero,
    GstRate.ofBasisPoints(500),
    GstRate.ofBasisPoints(1200),
    GstRate.ofBasisPoints(1800),
  ];

  /// The rate, as an exact count of basis points. This is what is persisted, both in the
  /// settings table and against every settled bill.
  final int basisPoints;

  /// True when no GST is charged at this rate.
  bool get isZero => basisPoints == 0;

  /// True when a bill at this rate carries a tax line.
  bool get isCharged => basisPoints > 0;

  /// True when this is a rate a bill may be settled at.
  ///
  /// Zero to 100%. A negative rate would add money to the customer's pocket and a rate
  /// above 100% would charge more tax than the food cost; neither is a tax rate, so
  /// neither is stored.
  bool get isAcceptable => basisPoints >= 0 && basisPoints <= maxBasisPoints;

  /// `18%`, or `12.5%` for a rate with a fraction of a percent.
  ///
  /// Built by integer division and remainder, so the label is exact. Trailing zeroes are
  /// dropped, because `5%` reads as a rate and `5.00%` reads as a calculation.
  String get label {
    final int percent = basisPoints ~/ basisPointsPerPercent;
    final int fraction = basisPoints.remainder(basisPointsPerPercent).abs();
    if (fraction == 0) {
      return '$percent%';
    }
    final String padded = fraction.toString().padLeft(2, '0');
    final String trimmed = padded.endsWith('0')
        ? padded.substring(0, 1)
        : padded;
    return '$percent.$trimmed%';
  }

  /// Half of this rate, which is what each of CGST and SGST is levied at, or `null`
  /// when the rate does not halve into a whole basis point.
  ///
  /// Rendered on a bill beside the two halves of the tax so the customer can check the
  /// arithmetic. It is a label and nothing else: the authoritative figure is the whole
  /// tax computed at [basisPoints], because halving the rate and applying it twice would
  /// round twice and could come to a paisa less than the tax actually charged. See
  /// `BillTotals.cgst`.
  ///
  /// `null` rather than a rounded label for an odd number of basis points, so the paper
  /// never states a rate that does not multiply out to the figure printed beside it.
  String? get halfLabel =>
      basisPoints.isEven ? GstRate.ofBasisPoints(basisPoints ~/ 2).label : null;

  /// The rate named by [stored], or `null` when it names none.
  ///
  /// Stored as the basis-point integer in text, because the settings table is text.
  /// Anything that is not a whole number, and any number outside 0–100%, reads as `null`
  /// rather than as zero: an unreadable rate is not the same fact as "no GST", and the
  /// caller decides which to fall back to.
  static GstRate? tryParseStored(String? stored) {
    if (stored == null) {
      return null;
    }
    final int? points = int.tryParse(stored.trim());
    if (points == null) {
      return null;
    }
    final GstRate rate = GstRate.ofBasisPoints(points);
    return rate.isAcceptable ? rate : null;
  }

  /// The rate for [basisPoints], or [zero] when it is not a rate a bill may carry.
  ///
  /// Used when reading a persisted bill: a stored rate that is out of range is a corrupt
  /// row, and reading it as zero shows the bill without its tax line rather than making
  /// the bill unopenable. The amounts on the bill are stored figures and are unaffected
  /// either way.
  static GstRate fromStoredBasisPoints(int basisPoints) {
    final GstRate rate = GstRate.ofBasisPoints(basisPoints);
    return rate.isAcceptable ? rate : zero;
  }

  /// This rate as it goes into the settings table.
  String toStored() => basisPoints.toString();

  @override
  int compareTo(GstRate other) => basisPoints.compareTo(other.basisPoints);

  @override
  bool operator ==(Object other) =>
      other is GstRate && other.basisPoints == basisPoints;

  @override
  int get hashCode => basisPoints.hashCode;

  @override
  String toString() => 'GstRate($label)';
}
