/// Application-wide constant values.
///
/// Anything that is genuinely configurable per outlet (outlet name, GSTIN,
/// address, UPI VPA, tax rates) does NOT belong here. Those values are owned by
/// the settings module and will be persisted in local storage, because they are
/// edited by the user rather than baked into the build.
class AppConstants {
  const AppConstants._();

  /// Display name of the product.
  static const String appName = 'Brisko Billing';

  /// Currency symbol used across the POS. The application is single-currency.
  static const String currencySymbol = '\u20B9';

  /// Number of decimal places money is rounded and displayed to.
  static const int currencyDecimals = 2;

  /// Breakpoint above which the shell uses a persistent side navigation rail
  /// instead of a bottom navigation bar. Sized for a billing tablet in
  /// landscape.
  static const double wideLayoutBreakpoint = 900;
}
