import 'dart:io';

/// Reads Dart source for tests that assert rules about the code rather than about a value.
///
/// Comments are stripped, because the files being checked discuss `double` in order to
/// explain why it is absent. A search over the raw text would report the very rule it is
/// checking and the test would be deleted for crying wolf.
///
/// The same stripping is done inside `money_discipline_test.dart`. It is repeated here
/// rather than shared out of that file so that adding the reports checks did not mean
/// editing an existing, passing test.
class DartSource {
  const DartSource._();

  /// The source at [path] with its block and line comments removed.
  static String codeOf(String path) {
    final String source = File(path).readAsStringSync();
    final String withoutBlocks = source.replaceAll(
      RegExp(r'/\*.*?\*/', dotAll: true),
      '',
    );
    return withoutBlocks.split('\n').map(_withoutLineComment).join('\n');
  }

  /// [line] up to a `//` that is not inside a string literal.
  ///
  /// The string check matters: a URL in a string contains `//`, and cutting the line there
  /// would hide real code from the search rather than a comment.
  static String _withoutLineComment(String line) {
    String? quote;

    for (int index = 0; index < line.length; index++) {
      final String character = line[index];

      if (quote != null) {
        if (character == r'\') {
          index++;
        } else if (character == quote) {
          quote = null;
        }
        continue;
      }

      if (character == "'" || character == '"') {
        quote = character;
        continue;
      }
      if (character == '/' &&
          index + 1 < line.length &&
          line[index + 1] == '/') {
        return line.substring(0, index);
      }
    }

    return line;
  }
}
