#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
./scripts/swift.sh build -c "$configuration"
app="$project_root/dist/Fieldwork.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/Fieldwork" "$app/Contents/MacOS/Fieldwork"
cp ".build/$configuration/fieldwork-cli" "$app/Contents/MacOS/fieldwork-cli"
cp ".build/$configuration/fieldwork-cli" "$project_root/dist/fieldwork"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Fieldwork</string>
<key>CFBundleDisplayName</key><string>Fieldwork</string>
<key>CFBundleIdentifier</key><string>local.fieldwork.research</string>
<key>CFBundleExecutable</key><string>Fieldwork</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
source .build/toolchain.env
icon_flags=()
if [[ -n "$FIELDWORK_SWIFT_OVERLAY" ]]; then
    icon_flags=(-vfsoverlay "$FIELDWORK_SWIFT_OVERLAY" -module-cache-path "$project_root/.build/fieldwork-module-cache")
fi
swiftc "${icon_flags[@]}" scripts/Icon.swift -o .build/make-icon
.build/make-icon .build/icon-1024.png
mkdir -p .build/AppIcon.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/icon-1024.png --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/icon-1024.png --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app/Contents/MacOS/fieldwork-cli"
codesign --force --sign - "$app"
echo "Built $app"
echo "Agent CLI: $project_root/dist/fieldwork"
