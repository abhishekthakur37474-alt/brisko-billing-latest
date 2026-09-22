/// Formats a slip's timestamp for the kitchen board.
///
/// Written by hand rather than pulled from `intl`: the board needs one 24-hour clock
/// format and nothing else, and a localisation package would be a dependency carried
/// for five lines of code.
class KitchenTicketTime {
  const KitchenTicketTime._();

  /// `14:05`, in the outlet's local time.
  ///
  /// Slip timestamps are stored in UTC, so they are converted here. A slip raised at
  /// 2pm has to read as 2pm to the person holding it.
  static String clock(DateTime at) {
    final DateTime local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
