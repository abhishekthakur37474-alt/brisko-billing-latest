import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/kitchen_ticket.dart';
import '../../domain/models/kot_status.dart';
import '../../domain/repositories/kot_repository.dart';

/// Holds the kitchen board: which slips are outstanding and what state each is in.
///
/// ## Reading
///
/// [load] replaces the whole board from the repository. It is called when the screen
/// is built, which for a shell section means every time the operator navigates to it,
/// and again by [refresh] when they ask for it. There is no polling and no cloud
/// stream: one terminal writes these rows, so re-reading on open is enough to be
/// correct.
///
/// ## Failure
///
/// Nothing in here throws. A repository failure becomes [errorMessage] and the board
/// falls back to empty, so a storage fault is something the operator reads on screen
/// rather than a red error box in place of the till.
class KitchenController extends ChangeNotifier {
  KitchenController({required this._kotRepository});

  /// Columns the board shows, in workflow order.
  static const List<KotStatus> boardStatuses = <KotStatus>[
    KotStatus.pending,
    KotStatus.preparing,
    KotStatus.ready,
  ];

  final KotRepository _kotRepository;

  List<KitchenTicket> _tickets = const <KitchenTicket>[];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  /// Slips whose status change is in flight, so their button can be disabled
  /// individually rather than locking the whole board.
  final Set<String> _advancing = <String>{};

  // ------------------------------------------------------------------- state ---

  /// Every outstanding slip, newest first.
  List<KitchenTicket> get tickets => _tickets;

  bool get isLoading => _isLoading;

  /// True once a read has finished, successfully or not. Distinguishes "nothing to
  /// cook" from "not read yet".
  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the board has been read and holds nothing.
  bool get isEmpty => _hasLoaded && _tickets.isEmpty;

  /// Slips in one column, newest first.
  List<KitchenTicket> ticketsAt(KotStatus status) => _tickets
      .where((KitchenTicket ticket) => ticket.status == status)
      .toList(growable: false);

  bool isAdvancing(String kotId) => _advancing.contains(kotId);

  // ----------------------------------------------------------------- intents ---

  /// Replaces the board from storage.
  ///
  /// Ignores a call made while a read is already running, so a double tap on refresh
  /// cannot interleave two reads and leave the later one's result discarded.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<KitchenTicket>> result = await _kotRepository
        .loadActiveTickets();

    result.fold<void>(
      onOk: (List<KitchenTicket> value) => _tickets = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        // Not the stale board: showing yesterday's slips beside an error message
        // would invite the kitchen to work from them.
        _tickets = const <KitchenTicket>[];
      },
    );

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  /// Re-reads the board on the operator's request.
  Future<void> refresh() => load();

  /// Moves [ticket] one step along the workflow, then re-reads the board.
  ///
  /// Does nothing for a slip that has nowhere to go, or one whose previous move is
  /// still in flight. The repository, not this controller, decides whether the move
  /// is legal, because only it can check the stored status and write in the same
  /// transaction; a rejection arrives here as [errorMessage].
  Future<void> advance(KitchenTicket ticket) async {
    final KotStatus? next = ticket.nextStep;
    if (next == null || _advancing.contains(ticket.id)) {
      return;
    }

    _advancing.add(ticket.id);
    _errorMessage = null;
    _notify();

    final Result<void> result = await _kotRepository.advanceStatus(
      ticket.id,
      next,
    );
    _advancing.remove(ticket.id);

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _notify();
      return;
    }

    // Re-read rather than mutate in place: the stored row is the truth, and a
    // refusal or a change made elsewhere shows up here.
    await load();
  }

  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Notifies unless the controller has already been disposed.
  ///
  /// A read or a status change can still be in flight when the operator navigates
  /// away, and notifying a disposed notifier is an error.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
