/// A snapshot of till data taken immediately before a clear.
class TillBackup {
  const TillBackup({
    required this.createdAt,
    required this.filePath,
    this.restaurantId,
  });

  final DateTime createdAt;

  /// Absolute path of the JSON file on this machine.
  final String filePath;

  /// Signed-in restaurant, when the cloud half was included.
  final String? restaurantId;
}
