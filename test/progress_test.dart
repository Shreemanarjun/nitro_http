import 'package:flutter_test/flutter_test.dart';
import 'package:nitro_http/nitro_http.dart';

void main() {
  group('fraction', () {
    test('is the completion ratio when the total is known', () {
      expect(
        const ProgressSnapshot(transferred: 25, total: 100).fraction,
        0.25,
      );
      expect(const ProgressSnapshot(transferred: 0, total: 100).fraction, 0.0);
      expect(const ProgressSnapshot(transferred: 100, total: 100).fraction, 1.0);
    });

    test('is null when the total is unknown, not zero', () {
      // A chunked response has no length. An indeterminate progress bar has to
      // be able to tell that apart from "not started", so this must not be 0.0.
      expect(const ProgressSnapshot(transferred: 10).fraction, isNull);
    });

    test('is null for a non-positive total', () {
      expect(const ProgressSnapshot(transferred: 0, total: 0).fraction, isNull);
      expect(const ProgressSnapshot(transferred: 5, total: -1).fraction, isNull);
    });

    test('can exceed 1.0 when more arrives than advertised', () {
      // A server that lies about Content-Length should not make this throw.
      expect(
        const ProgressSnapshot(transferred: 150, total: 100).fraction,
        1.5,
      );
    });
  });

  group('isComplete', () {
    test('is true once transferred reaches the total', () {
      expect(
        const ProgressSnapshot(transferred: 100, total: 100).isComplete,
        isTrue,
      );
      expect(
        const ProgressSnapshot(transferred: 101, total: 100).isComplete,
        isTrue,
      );
    });

    test('is false before the total is reached', () {
      expect(
        const ProgressSnapshot(transferred: 99, total: 100).isComplete,
        isFalse,
      );
    });

    test('is false when the total is unknown', () {
      expect(const ProgressSnapshot(transferred: 999).isComplete, isFalse);
    });
  });

  group('value semantics', () {
    test('equal snapshots compare equal and hash alike', () {
      const a = ProgressSnapshot(transferred: 5, total: 10);
      const b = ProgressSnapshot(transferred: 5, total: 10);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, same(a));
    });

    test('differing fields compare unequal', () {
      const base = ProgressSnapshot(transferred: 5, total: 10);

      expect(base, isNot(const ProgressSnapshot(transferred: 6, total: 10)));
      expect(base, isNot(const ProgressSnapshot(transferred: 5, total: 11)));
      expect(base, isNot(const ProgressSnapshot(transferred: 5)));
      expect(base, isNot(Object()));
    });
  });

  group('toString', () {
    test('renders a known total', () {
      expect(
        const ProgressSnapshot(transferred: 5, total: 10).toString(),
        'ProgressSnapshot(5/10)',
      );
    });

    test('renders an unknown total as a question mark', () {
      expect(
        const ProgressSnapshot(transferred: 5).toString(),
        'ProgressSnapshot(5/?)',
      );
    });
  });

  test('ProgressCallback accepts a nullable total', () {
    final seen = <(int, int?)>[];
    // ignore: prefer_function_declarations_over_variables
    final ProgressCallback callback = (transferred, total) =>
        seen.add((transferred, total));

    callback(10, 100);
    callback(20, null);

    expect(seen, [(10, 100), (20, null)]);
  });
}
