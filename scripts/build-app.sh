#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

build_args=(-c release)
if ! swift build "${build_args[@]}"; then
    # Some Command Line Tools releases cannot expand the current SwiftUI macro
    # plugin through the default Swift Build engine. Keep a reproducible fallback
    # for this Mac without changing the source package or the user's credentials.
    fallback_sdk="${GPT_TRANSLATOR_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
    if [[ ! -d "$fallback_sdk" ]]; then
        print -u2 "Swift build failed and fallback SDK was not found: $fallback_sdk"
        exit 1
    fi
    fallback_scratch="$(mktemp -d /tmp/gpttranslator-build.XXXXXX)"
    build_args=(--build-system native --sdk "$fallback_sdk" --scratch-path "$fallback_scratch" -c release)
    swift build "${build_args[@]}"
fi
binary_path="$(swift build "${build_args[@]}" --show-bin-path)/GPTTranslator"
applications_dir="${APP_OUTPUT_DIR:-$HOME/Applications}"
app_path="$applications_dir/GPT翻译助手.app"
app_version="${APP_VERSION:-1.0.0}"

mkdir -p "$applications_dir"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/GPTTranslator"
cp "$project_dir/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$project_dir/Assets/MenuBarIcon.png" "$app_path/Contents/Resources/MenuBarIcon.png"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"

cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>GPT 翻译助手</string>
	<key>CFBundleExecutable</key>
	<string>GPTTranslator</string>
	<key>CFBundleIdentifier</key>
	<string>com.gpttranslator.app</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleName</key>
	<string>GPTTranslator</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$app_version</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

signing_identity="${SIGNING_IDENTITY:-GPT Translator Local Code Signing}"
if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
    signing_identity="-"
fi

codesign \
    --force \
    --deep \
    --sign "$signing_identity" \
    --identifier com.gpttranslator.app \
    "$app_path" >/dev/null
print "已安装：$app_path"
