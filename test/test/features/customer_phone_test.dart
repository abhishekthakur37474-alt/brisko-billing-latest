import 'package:brisko_billing/features/customers/domain/models/customer_phone.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules for a customer's phone number.
///
/// Every number below is in the 90000000xx / 98765432xx range used by the rest of these
/// tests, so nothing here could be mistaken for a real customer of the outlet.
void main() {
  group('accepting a number', () {
    test('ten digits starting 6 to 9 are accepted as they are', () {
      for (final String number in <String>[
        '6000000001',
        '7000000001',
        '8000000001',
        '9876543210',
      ]) {
        expect(CustomerPhone.tryNormalise(number), number, reason: number);
        expect(CustomerPhone.isValid(number), isTrue, reason: number);
      }
    });

    test('spaces, dashes and brackets are removed', () {
      expect(CustomerPhone.tryNormalise('98765 43210'), '9876543210');
      expect(CustomerPhone.tryNormalise('98765-43210'), '9876543210');
      expect(CustomerPhone.tryNormalise('(98765) 43210'), '9876543210');
      expect(CustomerPhone.tryNormalise('  9876543210  '), '9876543210');
    });

    test('an Indian country code is removed', () {
      expect(CustomerPhone.tryNormalise('+919876543210'), '9876543210');
      expect(CustomerPhone.tryNormalise('+91 98765 43210'), '9876543210');
      expect(CustomerPhone.tryNormalise('919876543210'), '9876543210');
      expect(CustomerPhone.tryNormalise('00919876543210'), '9876543210');
    });

    test('a trunk prefix is removed', () {
      expect(CustomerPhone.tryNormalise('09876543210'), '9876543210');
    });

    test('every way of writing one number reaches the same stored form', () {
      const List<String> sameNumber = <String>[
        '9876543210',
        '98765 43210',
        '+91 98765 43210',
        '+919876543210',
        '09876543210',
        '0091 98765 43210',
      ];

      final Set<String?> stored = sameNumber
          .map(CustomerPhone.tryNormalise)
          .toSet();

      // One entry, which is what stops a customer ending up with two records and two
      // halves of one order history.
      expect(stored, <String>{'9876543210'});
    });
  });

  group('refusing a number', () {
    test('an empty or blank value is not a number', () {
      expect(CustomerPhone.tryNormalise(''), isNull);
      expect(CustomerPhone.tryNormalise('   '), isNull);
      expect(CustomerPhone.isBlank('   '), isTrue);
      expect(CustomerPhone.isBlank('9876543210'), isFalse);
    });

    test('a half-typed number is not yet a number', () {
      for (final String partial in <String>['9', '98', '987654', '987654321']) {
        expect(CustomerPhone.tryNormalise(partial), isNull, reason: partial);
      }
    });

    test('text with no digits is refused', () {
      expect(CustomerPhone.tryNormalise('not a number'), isNull);
    });

    test('a number outside the mobile range is refused', () {
      // Ten digits, but no Indian mobile number starts with 0 to 5.
      for (final String number in <String>[
        '0123456789',
        '1123456789',
        '2123456789',
        '5123456789',
      ]) {
        expect(CustomerPhone.tryNormalise(number), isNull, reason: number);
      }
    });

    test('extra digits are refused rather than trimmed off', () {
      // The regression this rule exists for. Keeping the first ten digits of these
      // would produce a valid-looking number belonging to somebody else.
      expect(CustomerPhone.tryNormalise('9000000001234'), isNull);
      expect(CustomerPhone.tryNormalise('98765432101'), isNull);
      expect(CustomerPhone.tryNormalise('900000000123'), isNull);
    });

    test('a prefix is only removed when ten digits are left', () {
      // Ten digits already, and it happens to begin 91. Stripping the 91 here would
      // invent a number nobody typed.
      expect(CustomerPhone.tryNormalise('9100000001'), '9100000001');
      // Eleven digits beginning 91 leaves nine, so it is refused rather than guessed at.
      expect(CustomerPhone.tryNormalise('91987654321'), isNull);
    });

    test('normalise throws with a message the cashier can act on', () {
      expect(
        () => CustomerPhone.normalise('12345'),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError error) => error.message,
            'message',
            CustomerPhone.requirement,
          ),
        ),
      );
    });

    test('normalise returns the stored form for a good number', () {
      expect(CustomerPhone.normalise('+91 98765 43210'), '9876543210');
    });
  });

  group('showing a number', () {
    test('a stored number is grouped for reading', () {
      expect(CustomerPhone.forDisplay('9876543210'), '98765 43210');
    });

    test('anything else is shown exactly as stored', () {
      // A record written before these rules existed is still the outlet's record of
      // that customer, so it is not dressed up.
      expect(CustomerPhone.forDisplay('12345'), '12345');
      expect(CustomerPhone.forDisplay(''), '');
    });
  });

  group('entry', () {
    test('digitsOf keeps only digits', () {
      expect(CustomerPhone.digitsOf('+91 (98765) 43210-x'), '919876543210');
      expect(CustomerPhone.digitsOf('abc'), '');
    });

    test('digitsOf stops at the length of an international number', () {
      final String kept = CustomerPhone.digitsOf('9' * 40);
      expect(kept.length, CustomerPhone.maxEnteredDigits);
    });

    test('digitsOf does not shorten a number to ten digits', () {
      // The field holds what was typed; whether it is usable is a separate question.
      expect(CustomerPhone.digitsOf('919876543210'), '919876543210');
    });
  });
}
