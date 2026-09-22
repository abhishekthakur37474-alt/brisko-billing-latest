import '../constants/app_constants.dart';
import 'money.dart';

/// Formats a [Money] for display.
///
/// Lives here rather than in a widget so that every screen renders an amount the
/// same way, and so the currency symbol is written once.
///
/// This is a one-way conversion, used at the very edge of the UI. Nothing parses the
/// result back: a total is always computed from [Money] values, never from the text
/// on screen.
extension MoneyDisplay on Money {
  /// The amount with the currency symbol, for example `₹1234.50`.
  String get formatted => '${AppConstants.currencySymbol}${toDecimalString()}';

  /// The amount with an explicit sign, for the price a customisation adds.
  ///
  /// Renders `+₹70.00`, or `Free` when the option genuinely costs nothing, so a
  /// zero-priced option does not look like a missing price.
  String get formattedAsAddition {
    if (isZero) {
      return 'Free';
    }
    return isNegative ? '-${(-this).formatted}' : '+$formatted';
  }
}
