import '../../../../core/utils/result.dart';
import '../models/customer.dart';
import '../models/customer_summary.dart';

/// Read and write access to customer records.
///
/// ## Phone numbers
///
/// Every method that takes a phone number normalises it through `CustomerPhone` first,
/// so `98765 43210`, `+91 98765 43210` and `09876543210` all reach the same record. The
/// lookups fall back to an exact match on what was passed when it cannot be normalised,
/// which keeps a partially typed number a miss rather than a failure, and keeps any
/// record written by an earlier build reachable.
abstract interface class CustomerRepository {
  /// Exact match on phone number, which is how the counter looks a customer up.
  Future<Result<Customer?>> findByPhone(String phone);

  Future<Result<Customer?>> findById(String id);

  /// Partial match on name or phone, for the search field.
  Future<Result<List<Customer>>> search(String query, {int limit});

  Future<Result<List<Customer>>> loadAll();

  Future<Result<void>> save(Customer customer);

  /// Returns the existing customer for [phone], or creates one.
  ///
  /// Exists as a single operation because doing it in two steps invites a duplicate
  /// record when the same number is entered twice in quick succession.
  ///
  /// Note that settlement does *not* go through here. It resolves the customer inside
  /// the transaction that writes the bill, so a sale that fails leaves no customer
  /// behind. This method is for the paths that genuinely want a customer record whether
  /// or not a bill follows.
  ///
  /// Returns a `ValidationFailure` when [phone] is empty or is not a usable number.
  Future<Result<Customer>> findOrCreateByPhone(String phone, {String? name});

  /// Customers with what their settled bills add up to, most recent visit first.
  ///
  /// Pass [query] to narrow by phone or name. One database round trip whatever the
  /// result size: the counts and totals are aggregated in the query rather than by
  /// asking about each customer in turn, so a directory of five hundred customers is
  /// still one read.
  ///
  /// Only settled bills are counted. See [CustomerSummary].
  Future<Result<List<CustomerSummary>>> loadDirectory({
    String? query,
    int limit,
  });

  /// One customer's totals, or `null` when the record is absent or deleted.
  Future<Result<CustomerSummary?>> loadSummary(String customerId);

  Future<Result<void>> delete(String id);
}
