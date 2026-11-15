#!/usr/bin/env sh
set -eu

REPO="KimliksizPro/emu-bridge"
APP_NAME="emu-bridge"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"

echo "==> Installing $APP_NAME..."

mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR"

# Install adb if missing (best-effort; do not abort if sudo is unavailable)
if ! command -v adb >/dev/null 2>&1; then
    echo "==> 'adb' not found. Attempting to install android-tools..."
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm android-tools || echo "Warning: Could not install android-tools automatically."
    elif command -v apt-get >/dev/null 2>&1; then
        (sudo apt-get update && sudo apt-get install -y adb) || echo "Warning: Could not install adb automatically."
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y android-tools || echo "Warning: Could not install android-tools automatically."
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y android-tools || echo "Warning: Could not install android-tools automatically."
    else
        echo "Warning: Please install 'adb' (android-tools) manually for your distro."
    fi
fi

# Prefer local build if running from repo, otherwise download universal x86_64 AppImage
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/build/$APP_NAME" ]; then
    echo "==> Using local build: $SCRIPT_DIR/build/$APP_NAME"
    install -Dm755 "$SCRIPT_DIR/build/$APP_NAME" "$BIN_DIR/$APP_NAME"
else
    ARCH="$(uname -m)"
    if [ "$ARCH" != "x86_64" ]; then
        echo "Error: Prebuilt AppImage is x86_64 only (detected: $ARCH). Build from source with ./bin/build." >&2
        exit 1
    fi
    echo "==> Downloading universal AppImage from GitHub Releases..."
    URL="https://github.com/$REPO/releases/latest/download/emu-bridge-x86_64.AppImage"
    TMP_BIN="$(mktemp "$BIN_DIR/.$APP_NAME.XXXXXX")"
    curl -fsSL -o "$TMP_BIN" "$URL"
    chmod 755 "$TMP_BIN"
    mv -f "$TMP_BIN" "$BIN_DIR/$APP_NAME"
fi

# Install icon (local or from repo)
if [ -f "$SCRIPT_DIR/pkgbuild/$APP_NAME.svg" ]; then
    install -Dm644 "$SCRIPT_DIR/pkgbuild/$APP_NAME.svg" "$ICON_DIR/$APP_NAME.svg"
else
    curl -fsSL -o "$ICON_DIR/$APP_NAME.svg" "https://raw.githubusercontent.com/$REPO/main/pkgbuild/$APP_NAME.svg"
fi

# Write XDG .desktop entry (works on KDE, GNOME, Hyprland, XFCE, etc.)
cat > "$APP_DIR/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ADB Bridge
Comment=Universal WebUSB to ADB bridge
Exec=$BIN_DIR/$APP_NAME
Icon=$ICON_DIR/$APP_NAME.svg
Terminal=false
Categories=Development;Utility;
Keywords=adb;android;webusb;bridge;
StartupNotify=true
EOF

# Refresh desktop & icon caches if available
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

echo "==> Done! 'ADB Bridge' is now in your app launcher."
echo "    Binary: $BIN_DIR/$APP_NAME"
