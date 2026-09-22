import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../auth/domain/services/manager_auth_service.dart';
import '../../domain/models/order.dart';
import '../../domain/repositories/order_repository.dart';

class OrderCancellationController extends ChangeNotifier {
  OrderCancellationController({
    required this.orderRepository,
    required this.managerAuthService,
  });

  final OrderRepository orderRepository;
  final ManagerAuthService managerAuthService;

  bool _isCancelling = false;
  String? _errorMessage;
  Order? _cancelledOrder;

  bool get isCancelling => _isCancelling;
  String? get errorMessage => _errorMessage;
  Order? get cancelledOrder => _cancelledOrder;

  void clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  Future<bool> cancelOrder({
    required String orderId,
    required String password,
    String? reason,
  }) async {
    if (_isCancelling) {
      return false;
    }

    _isCancelling = true;
    _errorMessage = null;
    notifyListeners();

    // 1. Verify password
    final Result<bool> authResult = await managerAuthService.verifyPassword(password);
    if (authResult.isErr) {
      _errorMessage = 'Could not verify manager authorization.';
      _isCancelling = false;
      notifyListeners();
      return false;
    }

    if (!authResult.valueOrNull!) {
      _errorMessage = 'Incorrect manager password.';
      _isCancelling = false;
      notifyListeners();
      return false;
    }

    // 2. Cancel order
    final Result<Order> cancelResult = await orderRepository.cancelOrder(
      orderId,
      cancellationReason: reason,
      // If we had a signed-in manager profile we'd pass it here, but we just know it's a manager
      authorizedBy: 'Manager',
    );

    if (cancelResult.isErr) {
      _errorMessage = _messageFor(cancelResult.failureOrNull!);
      _isCancelling = false;
      notifyListeners();
      return false;
    }

    _cancelledOrder = cancelResult.valueOrNull;
    _isCancelling = false;
    notifyListeners();
    return true;
  }

  static String _messageFor(AppFailure failure) {
    if (failure is ValidationFailure) {
      return failure.message;
    }
    return 'An error occurred while cancelling the order.';
  }
}
