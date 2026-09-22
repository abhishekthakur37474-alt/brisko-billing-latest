/// Renders a timestamp for a printed document.
///
/// Written by hand rather than taken from `intl`. A receipt needs one date format and
/// one time format, both fixed, and adding a localisation package with its data
/// tables for two lines of code would be a poor trade in an application that prints
/// for exactly one outlet.
///
/// Everything stored is UTC, and everything printed is local: a bill taken at 2pm has
/// to read as 2pm to the customer holding it.
class PrintTimestamp {
  const PrintTimestamp._();

  /// `11/09/2026`, in day-month-year order as used on Indian invoices.
  static String date(DateTime at) {
    final DateTime local = at.toLocal();
    return '${_two(local.day)}/${_two(local.month)}/${local.year}';
  }

  /// `14:05`, on a 24-hour clock so there is no am/pm to misread.
  static String time(DateTime at) {
    final DateTime local = at.toLocal();
    return '${_two(local.hour)}:${_two(local.minute)}';
  }

  /// `11/09/2026 14:05`.
  static String stamp(DateTime at) => '${date(at)} ${time(at)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
