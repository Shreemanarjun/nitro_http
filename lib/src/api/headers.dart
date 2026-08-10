/// Case-insensitive, order-preserving HTTP header storage.
library;

import 'dart:collection';

/// Header names whose values are never printed by [HttpHeaders.toString].
///
/// Headers land in logs, breadcrumbs and crash reports constantly; leaking a
/// bearer token or a session cookie that way is the single most common way a
/// credential escapes an app.
const Set<String> _redactedHeaderNames = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
};

/// An ordered, case-insensitive multimap of HTTP header fields.
///
/// HTTP header names are case-insensitive, but a header may legitimately
/// appear more than once (`Set-Cookie`, `Via`, `Warning`), and the order in
/// which fields were sent is observable. A plain `Map<String, String>` loses
/// both properties, so this class keeps the full ordered list of pairs and an
/// index over the lower-cased names for O(1) lookup.
class HttpHeaders {
  /// Creates an empty header collection.
  HttpHeaders();

  /// Creates headers from [map], preserving the map's iteration order.
  factory HttpHeaders.fromMap(Map<String, String> map) {
    final headers = HttpHeaders();
    map.forEach(headers.add);
    return headers;
  }

  /// Creates headers from ordered `(name, value)` pairs, keeping duplicates.
  factory HttpHeaders.fromEntries(Iterable<(String, String)> entries) {
    final headers = HttpHeaders();
    for (final (name, value) in entries) {
      headers.add(name, value);
    }
    return headers;
  }

  /// Every field in the order it was added, with the caller's original casing.
  final List<(String, String)> _entries = [];

  /// Lower-cased name to its values, in order. Redundant with [_entries], but
  /// it turns lookup and containment from a scan into a hash probe, and header
  /// lookup happens far more often than mutation.
  final Map<String, List<String>> _index = {};

  /// The first value for [name], or `null` when the header is absent.
  String? operator [](String name) => _index[name.toLowerCase()]?.first;

  /// Every value for [name], in order; empty when the header is absent.
  List<String> getAll(String name) {
    final values = _index[name.toLowerCase()];
    return values == null ? const [] : List<String>.unmodifiable(values);
  }

  /// Sets [name] to a single [value], replacing any existing values.
  ///
  /// The field keeps the position of the first existing occurrence, so
  /// overwriting a header does not shuffle it to the end of the list.
  void set(String name, String value) {
    final lower = name.toLowerCase();
    if (!_index.containsKey(lower)) {
      add(name, value);
      return;
    }
    var replaced = false;
    final kept = <(String, String)>[];
    for (final entry in _entries) {
      if (entry.$1.toLowerCase() != lower) {
        kept.add(entry);
        continue;
      }
      if (!replaced) {
        replaced = true;
        kept.add((name, value));
      }
    }
    _entries
      ..clear()
      ..addAll(kept);
    _index[lower] = [value];
  }

  /// Appends [value] under [name], keeping any values already present.
  void add(String name, String value) {
    _entries.add((name, value));
    (_index[name.toLowerCase()] ??= <String>[]).add(value);
  }

  /// Removes every value for [name]. Does nothing when it is absent.
  void remove(String name) {
    final lower = name.toLowerCase();
    if (_index.remove(lower) == null) return;
    _entries.removeWhere((entry) => entry.$1.toLowerCase() == lower);
  }

  /// Whether any field with [name] is present.
  bool containsKey(String name) => _index.containsKey(name.toLowerCase());

  /// Removes every field.
  void clear() {
    _entries.clear();
    _index.clear();
  }

  /// A live, unmodifiable view of every `(name, value)` pair in insertion
  /// order, duplicates included.
  Iterable<(String, String)> get entries =>
      UnmodifiableListView<(String, String)>(_entries);

  /// Every distinct header name, lower-cased, in first-seen order.
  Iterable<String> get names {
    final seen = <String>{};
    return [
      for (final entry in _entries)
        if (seen.add(entry.$1.toLowerCase())) entry.$1.toLowerCase(),
    ];
  }

  /// A flattened map where repeated fields are joined with `', '`.
  ///
  /// This is lossy — `Set-Cookie` in particular must never be folded this way
  /// when the result is going back onto the wire — but it is what most Dart
  /// HTTP APIs expect, so it is offered explicitly rather than implicitly.
  /// Keys use the casing of each header's first occurrence.
  Map<String, String> toMap() {
    final casing = <String, String>{};
    for (final entry in _entries) {
      casing.putIfAbsent(entry.$1.toLowerCase(), () => entry.$1);
    }
    return {
      for (final MapEntry(key: lower, value: values) in _index.entries)
        casing[lower] ?? lower: values.join(', '),
    };
  }

  /// The number of fields, counting duplicates separately.
  int get length => _entries.length;

  /// Whether no field is present.
  bool get isEmpty => _entries.isEmpty;

  /// Whether at least one field is present.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// A deep copy that shares no mutable state with this collection.
  HttpHeaders clone() => HttpHeaders.fromEntries(_entries);

  /// Adds every field of [other] to this collection, keeping duplicates.
  void addAll(HttpHeaders other) {
    for (final (name, value) in other._entries) {
      add(name, value);
    }
  }

  /// The `Content-Type` field value, or `null`.
  String? get contentType => this['content-type'];

  /// Sets or removes the `Content-Type` field.
  set contentType(String? value) {
    if (value == null) {
      remove('content-type');
    } else {
      set('Content-Type', value);
    }
  }

  /// The parsed `Content-Length`, or `null` when absent or not an integer.
  int? get contentLength {
    final raw = this['content-length'];
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }

  /// The `Location` field value, or `null`.
  String? get location => this['location'];

  /// Every `Set-Cookie` field value, in order.
  ///
  /// `Set-Cookie` is the header that most needs the multimap: folding several
  /// cookies into one comma-joined value corrupts `Expires` dates.
  List<String> get setCookie => getAll('set-cookie');

  /// Two collections are equal when they carry the same multiset of
  /// `(lower-cased name, value)` pairs.
  ///
  /// Order is deliberately ignored: two responses that list the same fields in
  /// a different order are the same set of headers, and tests should not have
  /// to care which order a server chose.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HttpHeaders) return false;
    if (_entries.length != other._entries.length) return false;
    if (_index.length != other._index.length) return false;
    for (final MapEntry(key: lower, value: mine) in _index.entries) {
      final theirs = other._index[lower];
      if (theirs == null || theirs.length != mine.length) return false;
      final a = [...mine]..sort();
      final b = [...theirs]..sort();
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  /// Summed rather than xor-ed so that a duplicated field still contributes —
  /// `h ^ h` would cancel out and collide with the empty collection.
  @override
  int get hashCode {
    var hash = 0;
    for (final entry in _entries) {
      hash = (hash + Object.hash(entry.$1.toLowerCase(), entry.$2)) & 0x3fffffff;
    }
    return hash;
  }

  @override
  String toString() {
    final parts = [
      for (final (name, value) in _entries)
        '$name: ${_redactedHeaderNames.contains(name.toLowerCase()) ? '<redacted>' : value}',
    ];
    return 'HttpHeaders(${parts.join(', ')})';
  }
}
