#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/BudgetApp/BudgetApp.xcodeproj"
SCHEME="BudgetApp"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<'EOF'
Usage:
  scripts/install-ios-build.sh simulator [SIMULATOR_UDID]
  scripts/install-ios-build.sh device DEVICE_UDID

Builds BudgetApp with xcodebuild, then installs the freshly built app from
Xcode DerivedData. This intentionally avoids ios/BudgetApp/build because that
folder can contain stale artifacts.
EOF
}

platform="${1:-}"
target_id="${2:-}"

if [[ "$platform" != "simulator" && "$platform" != "device" ]]; then
  usage
  exit 64
fi

if [[ "$platform" == "device" && -z "$target_id" ]]; then
  usage
  exit 64
fi

if [[ "$platform" == "simulator" && -z "$target_id" ]]; then
  target_id="$(xcrun simctl list devices booted | perl -ne 'print "$1\n" if /\(([0-9A-F-]{36})\) \(Booted\)/' | head -1)"
  if [[ -z "$target_id" ]]; then
    echo "No booted simulator found. Boot one in Xcode or pass a simulator UDID." >&2
    exit 66
  fi
fi

derived_data="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/BudgetAppInstall}"
rm -rf "$derived_data"

if [[ -d "$ROOT_DIR/ios/BudgetApp/Vendor/LinkKit.xcframework" ]]; then
  xattr -cr "$ROOT_DIR/ios/BudgetApp/Vendor/LinkKit.xcframework"
fi

if [[ "$platform" == "simulator" ]]; then
  destination="platform=iOS Simulator,id=$target_id"
  products_dir="$derived_data/Build/Products/$CONFIGURATION-iphonesimulator"
  app_path="$products_dir/BudgetApp.app"
else
  destination="id=$target_id"
  products_dir="$derived_data/Build/Products/$CONFIGURATION-iphoneos"
  app_path="$products_dir/BudgetApp.app"
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$destination" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$derived_data" \
  build

if [[ ! -d "$app_path" ]]; then
  echo "Build succeeded but app was not found at $app_path" >&2
  exit 70
fi

if [[ "$platform" == "simulator" ]]; then
  xcrun simctl install "$target_id" "$app_path"
  xcrun simctl launch "$target_id" com.hynix.budgetapp
else
  xcrun devicectl device install app --device "$target_id" "$app_path"
fi

echo "Installed $app_path"
