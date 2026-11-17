#!/usr/bin/env bash
#
# Sets the package version in the two places that state it: pubspec.yaml and
# the default user agent. test/raw_mapping_test.dart fails when they, or the
# first CHANGELOG.md heading, disagree.
#
#   tool/set-version.sh 0.0.8
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

version="${1:?usage: tool/set-version.sh <version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  { echo "not a version: $version" >&2; exit 2; }

sed -i.bak -E "s/^version: .*/version: $version/" pubspec.yaml
sed -i.bak -E "s#'nitro_http/[^']*'#'nitro_http/$version'#" lib/src/internal/raw_mapping.dart
rm -f pubspec.yaml.bak lib/src/internal/raw_mapping.dart.bak

echo "version $version: pubspec.yaml, lib/src/internal/raw_mapping.dart"
grep -q "^## $version\$" CHANGELOG.md ||
  echo "CHANGELOG.md has no '## $version' heading yet — add one before releasing."
