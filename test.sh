#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing in a
# non-default location; these flags point the build and loader at it.
set -euo pipefail
cd "$(dirname "$0")"
CLT=/Library/Developer/CommandLineTools
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xlinker -F -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
