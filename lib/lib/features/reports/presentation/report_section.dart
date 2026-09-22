/// The four reports the screen switches between.
///
/// Four rather than fifteen, because these are the ones a counter reads during a shift:
/// what came in, which bills made it up, what sold, and how it was paid. Anything that
/// needs a chart or a tax return is a separate piece of work.
///
/// Navigation metadata only. This enum does not know which widget draws each report; the
/// screen owns that mapping.
enum ReportSection {
  summary(label: 'Sales summary'),

  bills(label: 'Bills'),

  items(label: 'Item sales'),

  payments(label: 'Payment breakdown');

  const ReportSection({required this.label});

  /// Text on the tab.
  final String label;
}
