#!/usr/bin/env bash
# Finds md5 checksums in dune.lock/*.pkg, downloads the source,
# verifies the md5, computes sha512, and updates hashOverrides in nix/package.nix.
set -euo pipefail

LOCK_DIR="dune.lock"
NIX_FILE="nix/package.nix"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

declare -A overrides
declare -A url_cache  # url -> sha512

for pkg_file in "$LOCK_DIR"/*.pkg; do
  pkg_name=$(basename "$pkg_file" .pkg)

  # Extract url and checksum (handles multiline url fields)
  content=$(tr '\n' ' ' < "$pkg_file")
  url=$(echo "$content" | grep -oP '\(url\s+\K[^)]+' || true)
  url=$(echo "$url" | xargs)  # trim whitespace
  checksum=$(echo "$content" | grep -oP '\(checksum\s+\K[^)]+' || true)

  if [[ -z "$url" || -z "$checksum" ]]; then
    continue
  fi

  # Only process md5 checksums
  if [[ "$checksum" != md5=* ]]; then
    echo "  $pkg_name: already has ${checksum%%=*}, skipping"
    continue
  fi

  expected_md5="${checksum#md5=}"
  echo "Processing $pkg_name ($url)"

  if [[ -n "${url_cache[$url]:-}" ]]; then
    sha512="${url_cache[$url]}"
    echo "  cached sha512"
  else
    # Download
    dest="$TMPDIR/$pkg_name.tar.gz"
    curl -sL -o "$dest" "$url"

    # Verify md5
    actual_md5=$(md5sum "$dest" | cut -d' ' -f1)
    if [[ "$actual_md5" != "$expected_md5" ]]; then
      echo "  ERROR: md5 mismatch! expected=$expected_md5 actual=$actual_md5"
      exit 1
    fi
    echo "  md5 verified"

    # Compute sha512
    sha512=$(sha512sum "$dest" | cut -d' ' -f1)
    url_cache[$url]="$sha512"
  fi

  overrides[$pkg_name]="sha512=$sha512"
  echo "  sha512=$sha512"
done

if [[ ${#overrides[@]} -eq 0 ]]; then
  echo "No md5 checksums found to override."
  exit 0
fi

# Build the new hashOverrides block
indent="      "
lines=""
for pkg_name in $(echo "${!overrides[@]}" | tr ' ' '\n' | sort); do
  lines+="${indent}${pkg_name} = \"${overrides[$pkg_name]}\";\n"
done

# Replace hashOverrides block in nix/package.nix
# Match from "hashOverrides = {" to the closing "};"
python3 -c "
import re, sys

content = open('$NIX_FILE').read()
pattern = r'(hashOverrides\s*=\s*\{)[^}]*(};)'
replacement = r'\1\n${lines}${indent}\2'
new_content = re.sub(pattern, replacement, content, count=1)

if new_content == content:
    print('WARNING: Could not find hashOverrides block to update', file=sys.stderr)
    sys.exit(1)

open('$NIX_FILE', 'w').write(new_content)
"

echo ""
echo "Updated $NIX_FILE with ${#overrides[@]} hash override(s)."
