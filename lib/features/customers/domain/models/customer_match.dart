import 'customer_phone.dart';

/// A previous customer the cashier can pick while typing a name at checkout.
///
/// Built from stored customer rows and from names snapped onto settled bills, so a
/// walk-in who only gave a name is still offered. [phone] and [address] are the last
/// values on file for that person, not live fields: applying the match copies them
/// onto the bill being taken.
class CustomerMatch {
  const CustomerMatch({
    required this.name,
    this.phone,
    this.address,
    this.customerId,
    this.lastOrderAt,
  });

  final String name;

  /// Stored ten-digit number, or `null` when this person was billed without one.
  final String? phone;

  /// Last delivery address on a bill for this person, if any was taken.
  final String? address;

  /// The customer record, or `null` for a name that was never filed under a number.
  final String? customerId;

  final DateTime? lastOrderAt;

  /// Phone and address on one line, for the suggestion row.
  String get detailLine {
    final List<String> parts = <String>[];
    final String? storedPhone = phone?.trim();
    if (storedPhone != null && storedPhone.isNotEmpty) {
      parts.add(CustomerPhone.forDisplay(storedPhone));
    }
    final String? storedAddress = address?.trim();
    if (storedAddress != null && storedAddress.isNotEmpty) {
      parts.add(storedAddress);
    }
    if (parts.isEmpty) {
      return 'Previous bill';
    }
    return parts.join('  ·  ');
  }

  /// True when this row is the same person as [other]: same name, same number.
  bool isSamePersonAs(CustomerMatch other) {
    return name.trim().toLowerCase() == other.name.trim().toLowerCase() &&
        (phone ?? '') == (other.phone ?? '');
  }

  /// Prefers filled fields and the more recent visit.
  CustomerMatch mergedWith(CustomerMatch other) {
    final bool otherIsNewer =
        lastOrderAt == null ||
        (other.lastOrderAt != null && other.lastOrderAt!.isAfter(lastOrderAt!));
    final CustomerMatch newer = otherIsNewer ? other : this;
    final CustomerMatch older = otherIsNewer ? this : other;
    return CustomerMatch(
      name: newer.name.trim().isNotEmpty ? newer.name : older.name,
      phone: _firstNonEmpty(newer.phone, older.phone),
      address: _firstNonEmpty(newer.address, older.address),
      customerId: newer.customerId ?? older.customerId,
      lastOrderAt: newer.lastOrderAt ?? older.lastOrderAt,
    );
  }

  static String? _firstNonEmpty(String? preferred, String? fallback) {
    final String? cleanPreferred = preferred?.trim();
    if (cleanPreferred != null && cleanPreferred.isNotEmpty) {
      return cleanPreferred;
    }
    final String? cleanFallback = fallback?.trim();
    if (cleanFallback != null && cleanFallback.isNotEmpty) {
      return cleanFallback;
    }
    return null;
  }
}
