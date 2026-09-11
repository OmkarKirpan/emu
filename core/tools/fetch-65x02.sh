#!/usr/bin/env bash
# Fetch SingleStepTests/65x02's nes6502/v1 data set into this repo's
# gitignored cache, for `zig build test-cpu-sweep` (ENG-78).
#
# The full set is 256 files and about 1.08 GB, which is why it is fetched
# rather than vendored. Pass opcodes to fetch only those:
#
#     tools/fetch-65x02.sh            # all 256 (1.08 GB)
#     tools/fetch-65x02.sh 1e a9 00   # three files, about 15 MB
#
# Already-present files are left alone, so re-running it resumes.
#
# The data is MIT licensed; the parent repo SingleStepTests/ProcessorTests
# carries no license, so cite 65x02 itself.
set -euo pipefail

base_url="https://raw.githubusercontent.com/SingleStepTests/65x02/main/nes6502/v1"
dest="$(cd "$(dirname "$0")/.." && pwd)/.cache/65x02/nes6502/v1"
mkdir -p "$dest"

if [ "$#" -gt 0 ]; then
  opcodes=("$@")
else
  opcodes=()
  for n in $(seq 0 255); do opcodes+=("$(printf '%02x' "$n")"); done
fi

for raw in "${opcodes[@]}"; do
  # Accept `1e`, `1E` and `0x1e` alike.
  name="$(printf '%02x' "$((16#${raw#0x}))")"
  out="$dest/$name.json"
  if [ -s "$out" ]; then
    echo "have $name.json"
    continue
  fi
  echo "get  $name.json"
  curl -fsSL "$base_url/$name.json" -o "$out.part"
  mv "$out.part" "$out"
done

echo "data set in $dest"
