/// The rules for a customer's phone number: what is accepted, and how it is stored.
///
/// ## Why a normalised form exists
///
/// The phone number is the lookup key for a customer. A cashier who types
/// `98765 43210` today and `+91-98765-43210` tomorrow means the same person, and if
/// both were stored verbatim the outlet would end up with two records and two halves
/// of one order history. Everything is therefore reduced to the same ten digits before
/// it is written or looked up.
///
/// ## What is deliberately not done
///
/// Nothing here shortens a number to make it fit. An earlier version of the checkout
/// screen kept the first ten digits of whatever was typed, which turned
/// `+91 90000 00001` into `9190000000` — a real number belonging to somebody else,
/// stored silently as the customer's. Truncation is not a correction, so an input that
/// does not reduce to a valid number is refused and the cashier is told, rather than
/// filed under a different customer.
///
/// ## The accepted form
///
/// Ten digits beginning 6, 7, 8 or 9, which is the Indian mobile numbering range. An
/// international prefix (`+91`, `0091`) or a trunk prefix (`0`) is removed, but only
/// when exactly ten digits remain afterwards; otherwise the value is refused rather
/// than guessed at. Landlines are not accepted: the number is taken so a delivery
/// customer can be called back, and the outlet takes mobile numbers.
///
/// There is no arithmetic in this file, and no [double] anywhere near a phone number.
/// A phone number is an identifier that happens to be written with digits, so it is
/// handled as text throughout — leading zeros and all.
class CustomerPhone {
  const CustomerPhone._();

  /// Digits in the stored form.
  static const int digits = 10;

  /// Longest run of digits worth keeping from a text field.
  ///
  /// E.164 caps an international number at fifteen digits. Anything past that is a
  /// slipped keypress or a paste of something that is not a phone number, and there is
  /// no reason to carry it around.
  static const int maxEnteredDigits = 15;

  /// First digits an Indian mobile number can start with.
  static const String mobileLeadingDigits = '6789';

  /// What the cashier is told when a number is refused.
  static const String requirement =
      'Enter a 10-digit mobile number starting with 6, 7, 8 or 9';

  static final RegExp _nonDigits = RegExp(r'\D');

  /// Everything that is not a digit, removed, capped at [maxEnteredDigits].
  ///
  /// Used by the entry field so a number pasted as `+91 (98765) 43210` survives being
  /// typed. This is not the stored form: it may still be too short, too long, or start
  /// with a prefix. Use [tryNormalise] for that.
  static String digitsOf(String raw) {
    final String stripped = raw.replaceAll(_nonDigits, '');
    return stripped.length > maxEnteredDigits
        ? stripped.substring(0, maxEnteredDigits)
        : stripped;
  }

  /// The stored form of [raw], or `null` when it is not a number this outlet can use.
  ///
  /// Returns `null` rather than throwing, because the common caller is a text field
  /// being typed into and a half-entered number is not an error yet.
  static String? tryNormalise(String raw) {
    final String candidate = _stripPrefix(
      raw.trim().replaceAll(_nonDigits, ''),
    );

    if (candidate.length != digits) {
      return null;
    }
    if (!mobileLeadingDigits.contains(candidate[0])) {
      return null;
    }
    return candidate;
  }

  /// The stored form of [raw].
  ///
  /// Throws [ArgumentError] when [raw] is not usable. Thrown rather than returned
  /// because the callers are inside `SqliteErrorMapper.guard`, which turns an
  /// [ArgumentError] into a `ValidationFailure` carrying this message — so a bad phone
  /// number reaches the cashier the same way every other refused write does.
  static String normalise(String raw) {
    final String? normalised = tryNormalise(raw);
    if (normalised == null) {
      throw ArgumentError.value(raw, 'phone', requirement);
    }
    return normalised;
  }

  static bool isValid(String raw) => tryNormalise(raw) != null;

  /// True when [raw] holds nothing but whitespace, which means a walk-in.
  static bool isBlank(String raw) => raw.trim().isEmpty;

  /// `98765 43210`, for reading a stored number off the screen.
  ///
  /// Grouping only. Applied to the stored form, and never stored itself, so the value
  /// in the table stays the ten digits every lookup uses.
  static String forDisplay(String storedPhone) {
    if (storedPhone.length != digits) {
      // Anything else is shown exactly as stored. A number that predates these rules
      // is still the outlet's record of that customer, and dressing it up would
      // misrepresent what is in the table.
      return storedPhone;
    }
    return '${storedPhone.substring(0, 5)} ${storedPhone.substring(5)}';
  }

  /// Removes an international or trunk prefix, but only if ten digits are left.
  ///
  /// The guard is the whole point. `919876543210` is `+91` followed by a valid number,
  /// so the prefix goes. `9190000000` is ten digits already and is left alone, because
  /// stripping `91` there would invent a number nobody typed.
  static String _stripPrefix(String candidate) {
    if (candidate.length == digits) {
      return candidate;
    }
    if (candidate.length == digits + 4 && candidate.startsWith('0091')) {
      return candidate.substring(4);
    }
    if (candidate.length == digits + 2 && candidate.startsWith('91')) {
      return candidate.substring(2);
    }
    if (candidate.length == digits + 1 && candidate.startsWith('0')) {
      return candidate.substring(1);
    }
    return candidate;
  }
}
