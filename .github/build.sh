#!/bin/bash
# Builds the release files into build/ from the committed files (HEAD), so the release
# workflow and the tests use exactly the same zip.
#
#   .github/build.sh VERSION
#
# Leaves build/install.sh, build/stagehand.zip and build/VERSION, as described in
# workflows/release.yml.

set -euo pipefail

VERSION="${1:?usage: .github/build.sh VERSION}"

cd "$(dirname "$0")/.."
rm -rf build
mkdir -p build
git archive --format=tar --prefix=stagehand/ HEAD | tar -x -C build
echo "$VERSION" > build/stagehand/VERSION
cp build/stagehand/VERSION build/VERSION
cp build/stagehand/install.sh build/install.sh
(cd build && zip -qr stagehand.zip stagehand)
unzip -l build/stagehand.zip
