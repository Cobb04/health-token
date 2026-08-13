#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}
build_directory="$repository_root/.build/$configuration"
application_directory="$build_directory/HealthToken.app"

cd "$repository_root"
swift build --configuration "$configuration" --disable-index-store

mkdir -p "$application_directory/Contents/MacOS"
mkdir -p "$application_directory/Contents/Resources"
cp "$build_directory/HealthToken" "$application_directory/Contents/MacOS/HealthToken"
cp "$build_directory/HealthTokenHook" "$application_directory/Contents/MacOS/HealthTokenHook"
cp "$repository_root/Support/Info.plist" "$application_directory/Contents/Info.plist"

resource_bundle="$build_directory/HealthToken_HealthTokenApp.bundle"
if [ ! -d "$resource_bundle" ]; then
    resource_bundle="$build_directory/HealthTokenApp_HealthTokenApp.bundle"
fi
if [ -d "$resource_bundle" ]; then
    rm -rf "$application_directory/Contents/Resources/$(basename "$resource_bundle")"
    cp -R "$resource_bundle" "$application_directory/Contents/Resources/"
fi

echo "$application_directory"
