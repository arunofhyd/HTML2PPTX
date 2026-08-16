#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
APP_TARGET="/Users/arunthomas/Downloads/Presentation/HTML to PPTX Converter.app"

echo "🔨 Compiling SwiftUI Binary..."
swiftc -O -parse-as-library "$DIR/ConverterApp.swift" -o "$DIR/HTMLToPPTXConverter"

echo "📦 Assembling .app bundle at $APP_TARGET..."
rm -rf "$APP_TARGET"
mkdir -p "$APP_TARGET/Contents/MacOS"
mkdir -p "$APP_TARGET/Contents/Resources"

cp "$DIR/HTMLToPPTXConverter" "$APP_TARGET/Contents/MacOS/HTMLToPPTXConverter"
cp "$DIR/Info.plist" "$APP_TARGET/Contents/Info.plist"
cp "/Users/arunthomas/.gemini/antigravity-ide/scratch/converter_core.py" "$APP_TARGET/Contents/Resources/converter_core.py"
cp "$DIR/AppIcon.icns" "$APP_TARGET/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$DIR/AppLogo.png" "$APP_TARGET/Contents/Resources/AppLogo.png" 2>/dev/null || true

chmod +x "$APP_TARGET/Contents/MacOS/HTMLToPPTXConverter"
chmod +x "$APP_TARGET/Contents/Resources/converter_core.py"

echo "✨ Native Swift App successfully built!"
