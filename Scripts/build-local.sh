#!/bin/bash
set -euo pipefail

flavor="${1:-dev}"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common_git_dir="$(git -C "$script_root" rev-parse --path-format=absolute --git-common-dir)"
common_root="$(dirname "$common_git_dir")"
build_root="${PETRICHOR_LOCAL_BUILD_ROOT:-$common_root/.local-build}"

case "$flavor" in
    stable)
        configuration="Release"
        app_name="Petrichor Stable"
        bundle_id="org.Petrichor.zak.stable"
        url_scheme="petrichor-zak-stable"
        stable_ref="$(git -C "$script_root" rev-parse local-stable-v3)"
        current_ref="$(git -C "$script_root" rev-parse HEAD)"
        if [ "$current_ref" != "$stable_ref" ]; then
            echo "Build Stable from the pinned checkout: $common_root/.worktrees/stable" >&2
            exit 1
        fi
        git -C "$script_root" diff --quiet
        git -C "$script_root" diff --cached --quiet
        ;;
    dev)
        configuration="Debug"
        app_name="Petrichor Dev"
        bundle_id="org.Petrichor.zak.debug"
        url_scheme="petrichor-zak-dev"
        ;;
    *)
        echo "Usage: $0 [stable|dev]" >&2
        exit 1
        ;;
esac

if [ ! -f "$script_root/Configuration/Secrets.xcconfig" ]; then
    cp "$script_root/Configuration/Secrets.xcconfig.template" "$script_root/Configuration/Secrets.xcconfig"
fi

mkdir -p "$build_root"
xcodebuild build \
    -project "$script_root/Petrichor.xcodeproj" \
    -scheme Petrichor \
    -configuration "$configuration" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$build_root/$flavor" \
    -clonedSourcePackagesDirPath "$build_root/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    PETRICHOR_APP_NAME="$app_name" PETRICHOR_BUNDLE_ID="$bundle_id" \
    PETRICHOR_URL_SCHEME="$url_scheme" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp=none

app_path="$build_root/$flavor/Build/Products/$configuration/$app_name.app"
codesign --verify --deep --strict "$app_path"
echo "Built $app_path"
