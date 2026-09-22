import '../../../core/error/app_failure.dart';
import '../../../core/utils/result.dart';
import '../../settings/domain/models/setting_keys.dart';
import '../../settings/domain/repositories/settings_repository.dart';
import '../domain/models/business_identity.dart';
import '../domain/models/monochrome_bitmap.dart';

/// Reads the outlet's printed details out of settings.
///
/// ## Why a class rather than six reads at the call site
///
/// The receipt formatter needs one value object; the settings table holds eight
/// independent keys. Assembling them here means the interpretation of a blank setting
/// lives in one place, and the formatter cannot accidentally read a key directly and
/// start printing an empty `GSTIN ` label.
///
/// ## A missing setting is not an error
///
/// A terminal that has not been configured yet still has to be able to print a bill.
/// Every read that fails or returns nothing falls back to absent, and an absent field
/// is simply not printed. Nothing here invents an address, a telephone number, a GSTIN
/// or a UPI address: those are legal and financial identifiers, and a plausible-looking
/// placeholder is far more dangerous than a blank line.
class SettingsBusinessIdentitySource {
  const SettingsBusinessIdentitySource({required this.settings, this.logo});

  final SettingsRepository settings;

  /// The outlet logo to stamp on every receipt, already reduced to printable dots, or
  /// `null` when none is bundled.
  ///
  /// Supplied once at start-up. It is not a setting the operator types; it is an asset
  /// decoded by the app layer, where an image codec is available, and handed down here
  /// so the pure printing pipeline receives only finished bits. A build without the
  /// logo asset passes `null`, and the receipt prints a header with just the name.
  final MonochromeBitmap? logo;

  /// The outlet's details as currently configured.
  ///
  /// Never fails. A storage fault reading a receipt header must not stop a sale being
  /// printed, so it degrades to [BusinessIdentity.unconfigured], which carries the
  /// outlet name and claims nothing else.
  Future<BusinessIdentity> load() async {
    final String? name = await _read(SettingKeys.businessName);

    return BusinessIdentity(
      name: name ?? BusinessIdentity.defaultName,
      address: await _read(SettingKeys.businessAddress),
      phone: await _read(SettingKeys.businessPhone),
      gstin: await _read(SettingKeys.gstin),
      receiptHeader: await _read(SettingKeys.receiptHeader),
      receiptFooter: await _read(SettingKeys.receiptFooter),
      feedbackUrl: await _read(SettingKeys.feedbackUrl),
      logo: logo,
    );
  }

  /// The outlet's UPI address, or `null` when none is configured.
  Future<String?> upiVpa() => _read(SettingKeys.upiVpa);

  /// The payee name shown in the customer's UPI application.
  Future<String?> upiPayeeName() => _read(SettingKeys.upiPayeeName);

  /// A setting, or `null` when absent, blank or unreadable.
  Future<String?> _read(String key) async {
    final Result<String?> result = await settings.readString(key);
    final String? value = result.fold<String?>(
      onOk: (String? stored) => stored,
      onErr: (AppFailure _) => null,
    );
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
