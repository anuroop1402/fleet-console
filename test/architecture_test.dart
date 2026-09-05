/// The layer boundary, enforced rather than merely documented.
///
/// Clean Architecture survives exactly as long as someone is checking. The
/// first time a BLoC needs "just one field" from a DuckDB row, the pressure is
/// to import it directly — and once one import crosses the line, the domain
/// stops being testable without a database and nobody notices until it is
/// expensive to undo.
///
/// This test reads the actual import statements off disk. It costs a few
/// milliseconds and it is the reason `flutter test` can run the whole domain
/// suite without a native library.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What `lib/domain/` is allowed to depend on.
///
/// `dart:math` earns its place: haversine is trigonometry, and it is pure. It
/// is not an I/O escape hatch.
const _allowedDomainImports = {'dart:core', 'dart:math', 'package:equatable'};

/// Things that must never appear in the domain layer, with the reason.
const _forbiddenAnywhereInDomain = {
  'package:flutter/': 'the domain must not know about the UI toolkit',
  'package:dart_duckdb': 'the domain must not know how it is persisted',
  'package:get_it': 'the domain must not resolve its own dependencies',
  'package:flutter_bloc': 'the domain must not know about presentation',
  'dart:io': 'the domain must be free of I/O',
  'dart:isolate': 'the domain must be free of concurrency plumbing',
  'dart:ffi': 'the domain must be free of native bindings',
};

void main() {
  group('lib/domain is independent', () {
    final files = _dartFilesUnder('lib/domain');

    test('there are domain files to check', () {
      // Guards against the whole suite silently passing because a path changed.
      expect(files, isNotEmpty);
    });

    test('imports nothing outside dart:core, dart:math and equatable', () {
      final violations = <String>[];

      for (final file in files) {
        for (final import in _importsOf(file)) {
          // Relative imports stay inside the layer, which is what we want.
          if (!import.startsWith('dart:') && !import.startsWith('package:')) {
            continue;
          }
          final allowed = _allowedDomainImports.any(import.startsWith);
          if (!allowed) {
            violations.add('${_relative(file)} imports $import');
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'The domain layer must stay free of infrastructure.\n'
            '${violations.join('\n')}',
      );
    });

    test('never reaches into data/ or presentation/', () {
      final violations = <String>[];

      for (final file in files) {
        for (final import in _importsOf(file)) {
          if (import.contains('/data/') ||
              import.contains('/presentation/') ||
              import.contains('/app/') ||
              import.startsWith('../data/') ||
              import.startsWith('../presentation/') ||
              import.startsWith('../app/')) {
            violations.add('${_relative(file)} imports $import');
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('imports none of the explicitly forbidden packages', () {
      final violations = <String>[];

      for (final file in files) {
        for (final import in _importsOf(file)) {
          for (final entry in _forbiddenAnywhereInDomain.entries) {
            if (import.startsWith(entry.key)) {
              violations.add(
                '${_relative(file)} imports ${entry.key} — ${entry.value}',
              );
            }
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('presentation depends only on the domain', () {
    final files = _dartFilesUnder('lib/presentation');

    test('never imports the data layer or DuckDB', () {
      // A BLoC that can reach infrastructure eventually will. The first time
      // one needs a field that no use case exposes, importing the repository
      // implementation is the path of least resistance — and after that the
      // presentation layer cannot be tested without a native library.
      final violations = <String>[];

      for (final file in files) {
        for (final import in _importsOf(file)) {
          final reachesData =
              import.contains('/data/') || import.startsWith('../data/');
          final reachesInfra =
              import.startsWith('package:dart_duckdb') ||
              import.startsWith('dart:ffi');
          if (reachesData || reachesInfra) {
            violations.add('${_relative(file)} imports $import');
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('reaches repositories only through use cases', () {
      // The dependency rule is BLoC -> use case -> repository interface. A BLoC
      // holding a repository directly skips the layer that owns orchestration
      // and clock injection, which is where the interesting logic lives.
      final violations = <String>[];

      for (final file in files) {
        for (final import in _importsOf(file)) {
          if (import.contains('domain/repositories/') ||
              import.contains('/repositories/')) {
            violations.add(
              '${_relative(file)} imports $import — go through a use case',
            );
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('the composition root is the only place that wires concretes', () {
    test('nothing outside lib/app constructs the DuckDB repository', () {
      // get_it is a service locator, and a service locator used from a widget
      // is a global variable with extra steps. Only lib/app may resolve.
      final violations = <String>[];

      for (final dir in ['lib/domain', 'lib/presentation']) {
        for (final file in _dartFilesUnder(dir)) {
          for (final import in _importsOf(file)) {
            if (import.startsWith('package:get_it')) {
              violations.add('${_relative(file)} imports get_it');
            }
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('rules and reducers are pure', () {
    test('never read the clock directly', () {
      // `now` is always a parameter. A hidden DateTime.now() makes a rule's
      // tests assert the machine and the moment they ran, and makes staleness
      // untestable without sleeping.
      final violations = <String>[];

      for (final dir in ['lib/domain/rules', 'lib/domain/reducers']) {
        for (final file in _dartFilesUnder(dir)) {
          final source = file.readAsStringSync();
          final code = source
              .split('\n')
              .where((line) => !line.trimLeft().startsWith('//'))
              .join('\n');
          if (code.contains('DateTime.now()')) {
            violations.add('${_relative(file)} calls DateTime.now()');
          }
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });
}

List<File> _dartFilesUnder(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

/// Import targets in a file, ignoring anything inside a `//` comment.
Iterable<String> _importsOf(File file) sync* {
  final pattern = RegExp("""^\\s*import\\s+['"]([^'"]+)['"]""", multiLine: true);
  for (final match in pattern.allMatches(file.readAsStringSync())) {
    yield match.group(1)!;
  }
}

String _relative(File file) =>
    file.path.replaceFirst('${Directory.current.path}/', '');
