/// Outcome of merging a batch of cloud records into local storage.
///
/// The download half of synchronisation is not a blind overwrite: a record that
/// is older in the cloud than on this terminal must not clobber the newer local
/// copy, because the local copy might be a bill this terminal has just taken and
/// not yet uploaded. This report says, for one batch, how many records were
/// actually written and how many were held back to protect newer local data.
///
/// It exists so the coordinator can log conflicts rather than lose them silently,
/// which is the requirement for historical financial records.
class RemoteMergeReport {
  const RemoteMergeReport({required this.applied, required this.keptLocal});

  const RemoteMergeReport.empty() : applied = 0, keptLocal = 0;

  /// Cloud records that were newer (or absent locally) and were written.
  final int applied;

  /// Cloud records that were older than or equal to the local copy and were
  /// therefore not written, so the newer local record survives. Each one is a
  /// conflict resolved in favour of local.
  final int keptLocal;

  int get total => applied + keptLocal;

  RemoteMergeReport operator +(RemoteMergeReport other) => RemoteMergeReport(
    applied: applied + other.applied,
    keptLocal: keptLocal + other.keptLocal,
  );
}
