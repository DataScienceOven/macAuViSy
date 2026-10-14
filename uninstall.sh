#!/bin/bash
echo "Uninstalling macAuViSy..."

echo "1. Stopping any running instances..."
killall macAuViSy 2>/dev/null || true

echo "2. Purging macOS Privacy & Security permissions (TCC database)..."
tccutil reset All com.opensource.macAuViSy >/dev/null 2>&1 || true

echo "3. Erasing User Defaults and Application Preferences..."
defaults delete com.opensource.macAuViSy 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.opensource.macAuViSy.plist"
rm -rf "$HOME/Library/Saved Application State/com.opensource.macAuViSy.savedState"

echo "4. Removing the application bundle from /Applications..."
rm -rf "/Applications/macAuViSy.app"

killall Dock 2>/dev/null || true

echo "✅ Uninstall Complete! All residues, preferences, and permissions have been cleanly wiped (Launchpad refreshed)."
