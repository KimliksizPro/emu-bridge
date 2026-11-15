# ADB WebUSB Bridge (`emu-bridge`)

Lightweight native C++ / Qt Quick desktop app that bridges browser WebUSB (`navigator.usb`) to your local ADB server (`127.0.0.1:5037`) over WebSocket — with zero Node.js or Python runtime dependencies.

## Features

- Native WebSocket ↔ ADB (`127.0.0.1:5037`) bridge in C++
- Automatic ADB device discovery and selection
- One-click JS `navigator.usb` hook copy to clipboard
- Dark & Light theme (`T`)
- Keyboard shortcuts: `Space` Start/Stop, `R` Refresh, `C` Copy JS, `T` Toggle Theme, `Q` Quit

## Quick Install (Any Linux Distro: Arch, Ubuntu, Fedora, openSUSE — KDE / GNOME / Hyprland)

```sh
curl -fsSL https://raw.githubusercontent.com/KimliksizPro/emu-bridge/main/install.sh | sh
```

## Build from source

Requires `qt6-base`, `qt6-declarative`, `qmake6`, `make`, and `adb` at runtime.

```sh
./bin/build
./build/emu-bridge
```

## Install to App Launcher (Arch / Omarchy)

```sh
./bin/install
```
