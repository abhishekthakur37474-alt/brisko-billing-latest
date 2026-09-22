/// The rules for the outlet's GST identification number.
///
/// ## Why this is validated at all
///
/// A GSTIN is printed on the customer's bill as a tax identifier. A number with a
/// digit missing is worse than a blank line: the bill looks like a compliant tax
/// invoice and is not one. So a GSTIN that has been entered is checked, and a GSTIN
/// that has not been entered is simply absent — which the receipt already handles by
/// omitting the line.
///
/// ## The structure
///
/// Fifteen characters, in the form the GST Council defines:
///
/// ```
/// 2 7 A A P F U 0 9 3 9 F 1 Z V
/// | | |         |         | | |
/// | | +- PAN, 5 letters, 4 digits, 1 letter
/// | |                              |  | +- check character
/// | |                              |  +- always Z
/// | |                              +- entity number for that PAN in that state
/// +-+- state code, 2 digits
/// ```
///
/// ## What is deliberately not done
///
/// The fifteenth character is a check character computed over the first fourteen. It
/// is **not** verified here. The arithmetic is not published as a specification, only
/// described second-hand, and a check implemented from a description that turns out to
/// differ in one detail would refuse a real outlet's real GSTIN — which is a far worse
/// outcome than accepting a mistyped one, because it stops the owner configuring their
/// own till. Structure is checked; the digit is trusted to the person reading it off
/// their registration certificate.
///
/// Nothing here shortens, pads or repairs a value. An input that is not a GSTIN is
/// refused and the operator is told, rather than stored as something they did not type.
class Gstin {
  const Gstin._();

  /// Characters in a GSTIN.
  static const int length = 15;

  /// What the operator is told when a GSTIN is refused.
  static const String requirement =
      'A GSTIN is 15 characters: 2 digits, then a 10-character PAN, then a '
      'digit or letter, then Z, then one more digit or letter';

  /// State code, PAN, entity number, the literal Z, and the check character.
  ///
  /// Anchored at both ends, so trailing rubbish cannot pass.
  static final RegExp _structure = RegExp(
    r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$',
  );

  /// True when [raw] holds nothing but whitespace.
  ///
  /// An outlet that is not registered for GST, or has not been given its number yet,
  /// leaves this blank and no GSTIN line is printed.
  static bool isBlank(String raw) => raw.trim().isEmpty;

  /// The stored form of [raw], or `null` when it is not a GSTIN.
  ///
  /// Trimmed and upper-cased. That is not a repair: a GSTIN's alphabet is upper case
  /// by definition, so `27aapfu0939f1zv` is the same identifier typed with caps lock
  /// off, and the value the operator sees in the field after saving is the value that
  /// was stored. A string that does not match the structure is returned as `null`
  /// rather than being adjusted until it does.
  static String? tryNormalise(String raw) {
    final String candidate = raw.trim().toUpperCase();
    return _structure.hasMatch(candidate) ? candidate : null;
  }

  /// True when [raw] is blank, or is a well-formed GSTIN.
  ///
  /// Blank is valid because the setting is optional.
  static bool isAcceptable(String raw) =>
      isBlank(raw) || tryNormalise(raw) != null;

  /// The two-digit state code, or `null` when [storedGstin] is not a GSTIN.
  ///
  /// Not used on the receipt. Exposed because it is the one part of the number that
  /// carries meaning on its own, and reading it back is cheaper than re-deriving the
  /// offsets at a call site.
  static String? stateCodeOf(String storedGstin) {
    final String? normalised = tryNormalise(storedGstin);
    return normalised?.substring(0, 2);
  }
}
