#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
APP_TARGET="/Users/arunthomas/Downloads/Presentation/HTML2PPTX.app"

# Single Source of Truth: Read version from version.json
VERSION=$(python3 -c "import json, os; p = '$DIR/version.json' if os.path.exists('$DIR/version.json') else '/Users/arunthomas/HTML2PPTX/version.json'; print(json.load(open(p))['version'])" 2>/dev/null || echo "1.0.2")
echo "🔖 Building HTML2PPTX v$VERSION..."

echo "🔨 Compiling SwiftUI Binary..."
swiftc -O -parse-as-library "$DIR/ConverterApp.swift" -o "$DIR/HTML2PPTX"

echo "📦 Assembling .app bundle at $APP_TARGET..."
rm -rf "$APP_TARGET" "/Users/arunthomas/Downloads/Presentation/HTML to PPTX Converter.app"
mkdir -p "$APP_TARGET/Contents/MacOS"
mkdir -p "$APP_TARGET/Contents/Resources"

cp "$DIR/HTML2PPTX" "$APP_TARGET/Contents/MacOS/HTML2PPTX"
cp "$DIR/Info.plist" "$APP_TARGET/Contents/Info.plist"

# Stamp Info.plist with version from version.json
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true

cp "/Users/arunthomas/.gemini/antigravity-ide/scratch/converter_core.py" "$APP_TARGET/Contents/Resources/converter_core.py"
cp "$DIR/AppIcon.icns" "$APP_TARGET/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$DIR/AppLogo.png" "$APP_TARGET/Contents/Resources/AppLogo.png" 2>/dev/null || true
cp "$DIR/AppIcon.png" "$APP_TARGET/Contents/Resources/AppIcon.png" 2>/dev/null || true
cp "$DIR/logo.svg" "$APP_TARGET/Contents/Resources/logo.svg" 2>/dev/null || true

chmod +x "$APP_TARGET/Contents/MacOS/HTML2PPTX"
chmod +x "$APP_TARGET/Contents/Resources/converter_core.py"

# Also symlink for compatibility
ln -s "$APP_TARGET" "/Users/arunthomas/Downloads/Presentation/HTML to PPTX Converter.app" 2>/dev/null || true

echo "✨ Native Swift App HTML2PPTX v$VERSION successfully built!"

# Install to /Applications
DEST="/Applications/HTML2PPTX.app"
pkill -x "HTML2PPTX" 2>/dev/null || true
rm -rf "" 2>/dev/null || true
cp -R "" "" 2>/dev/null || true
