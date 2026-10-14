#!/bin/bash
set -e

APP_NAME="macAuViSy"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Gracefully terminate any running instance before compiling or reinstalling
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "⚠️  Detected running instance of $APP_NAME. Gracefully closing before reinstalling..."
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    sleep 1
    if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        killall "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
    if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        killall -9 "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
    echo "Previous instance closed."
fi

echo "Installing dependencies & Compiling App..." 
swift build -c release -Xlinker -w 2>&1 | python3 -c '
import sys, re
for line in sys.stdin:
    m = re.search(r"\[(\d+)\D+?(\d+)\]", line)
    if m:
        try:
            c, t = int(m.group(1)), int(m.group(2))
            if t > 0:
                sys.stdout.write(f"\rInstalling... {int((c/t)*100)}%   ")
                sys.stdout.flush()
        except:
            pass
print("\rInstalling... 100% (Done!)")
'
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Creating Application Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Resizing Custom Menu Bar Icon..."
if [ -f "assets/MenuIcon.png" ]; then
    sips --resampleHeight 16 "assets/MenuIcon.png" --out "$RESOURCES_DIR/MenuIcon.png" > /dev/null
    sips --resampleHeight 32 "assets/MenuIcon.png" --out "$RESOURCES_DIR/MenuIcon@2x.png" > /dev/null
    sips --resampleHeight 48 "assets/MenuIcon.png" --out "$RESOURCES_DIR/MenuIcon@3x.png" > /dev/null
elif [ -f "assets/icon.jpg" ]; then
    sips -s format png --resampleHeight 16 "assets/icon.jpg" --out "$RESOURCES_DIR/MenuIcon.png" > /dev/null
    sips -s format png --resampleHeight 32 "assets/icon.jpg" --out "$RESOURCES_DIR/MenuIcon@2x.png" > /dev/null
    sips -s format png --resampleHeight 48 "assets/icon.jpg" --out "$RESOURCES_DIR/MenuIcon@3x.png" > /dev/null
fi

echo "Copying executable..."
cp ".build/release/UnifiedControl" "$MACOS_DIR/$APP_NAME"

echo "Creating Info.plist..."
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.opensource.macAuViSy</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo "Generating Icon..."
if [ -f "assets/icon.jpg" ]; then
    ICONSET_DIR="AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -s format png -z 16 16     "assets/icon.jpg" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
    sips -s format png -z 32 32     "assets/icon.jpg" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
    sips -s format png -z 32 32     "assets/icon.jpg" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
    sips -s format png -z 64 64     "assets/icon.jpg" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
    sips -s format png -z 128 128   "assets/icon.jpg" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
    sips -s format png -z 256 256   "assets/icon.jpg" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
    sips -s format png -z 256 256   "assets/icon.jpg" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
    sips -s format png -z 512 512   "assets/icon.jpg" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
    sips -s format png -z 512 512   "assets/icon.jpg" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
    sips -s format png -z 1024 1024 "assets/icon.jpg" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
fi

echo "Signing the App bundle..."
codesign --force --deep -r='designated => identifier "com.opensource.macAuViSy"' --sign - "$APP_BUNDLE"

if [ "$CI" = "true" ] || [ "$GITHUB_ACTIONS" = "true" ]; then
    echo "✅ Build Complete! (CI environment detected, skipping installation to /Applications)"
else
    if [ -d "/Applications/$APP_BUNDLE" ]; then
        echo "Updating existing installation in /Applications..."
        rm -rf "/Applications/$APP_BUNDLE"
    else
        echo "Installing to /Applications..."
    fi
    mv "$APP_BUNDLE" "/Applications/"
    
    echo "✅ Build & Install Complete!"
    echo "The application has been cleanly installed to /Applications/$APP_BUNDLE."
fi
