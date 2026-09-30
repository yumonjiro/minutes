#!/bin/sh
# Release 版のアプリを作り、build/Minutes.app に置く。モデルは同梱せず、アプリが初回に Hugging Face から取得する。
#
# 使い方: scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."
# 依存は MinutesKit で解決し、その版をアプリのプロジェクトにも使う
(cd MinutesKit && swift package resolve --scratch-path ../.spm)
cp MinutesKit/Package.resolved Minutes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# 手元用のアドホック署名なので Hardened Runtime を外す（Team ID の無い署名では、同梱したライブラリの読み込みが
# ライブラリの検証で止められることがある）。配布するときは Xcode で Team を設定して Archive し、公証する
xcodebuild -project Minutes.xcodeproj -scheme Minutes -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/dd-release -clonedSourcePackagesDirPath .spm -disableAutomaticPackageResolution \
  -skipMacroValidation -skipPackagePluginValidation ENABLE_HARDENED_RUNTIME=NO build | grep -E "error:|warning: .*/Minutes/|\*\* BUILD" || true
mkdir -p build
rm -rf build/Minutes.app
cp -cR .build/dd-release/Build/Products/Release/Minutes.app build/
echo "→ $(pwd)/build/Minutes.app"
