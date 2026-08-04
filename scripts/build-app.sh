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
cp "$repository_root/Support/Info.plist" "$application_directory/Contents/Info.plist"

echo "$application_directory"
