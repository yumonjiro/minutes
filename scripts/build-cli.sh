#!/bin/sh
# 確認用の CLI（diarize・transcribe・tidy）を作り、build/cli/ に置く。
# MLX の Metal のライブラリを作るため、swift build ではなく xcodebuild でビルドする。
#
# 使い方: scripts/build-cli.sh
set -eu
cd "$(dirname "$0")/.."
products=.build/dd-cli/Build/Products/Release
for scheme in diarize transcribe tidy; do
  (cd MinutesKit && xcodebuild -scheme "$scheme" -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath ../.build/dd-cli -clonedSourcePackagesDirPath ../.spm \
    -skipMacroValidation -skipPackagePluginValidation build 2>&1 | grep -E "error:|\*\* BUILD" || true)
done
# 実行ファイルと、実行に要るリソース（.bundle）を並べて置く
rm -rf build/cli
mkdir -p build/cli
cp "$products/diarize" "$products/transcribe" "$products/tidy" build/cli/
cp -R "$products"/*.bundle build/cli/
echo "→ $(pwd)/build/cli"
