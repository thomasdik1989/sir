# Simple Input Relay in objective-c (or CSir because the c version performs better)

Native Objective-C++ version using ScreenCaptureKit for future macOS compatibility.
I tried refactoring the python version into C using CGWindowListCreateImage but that won't support future versions of Macos and gave a warning containing ScreenCaptureKit.
I had a look at https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/snapshot/snapshot_mac.mm
and read the manual https://developer.apple.com/documentation/screencapturekit/ for this.

## Requirements

- macOS 12.3+
- Xcode Command Line Tools (`xcode-select --install`)
- libwebsockets (`brew install libwebsockets`)

## Build

```bash
make
```

## Usage

```bash
./csir
```

The server prints a URL like `http://192.168.x.x:8080`. Open that URL in Safari on your iPad.

Open a drawing application on your MacBook, then draw on the iPad screen.

## macOS Permissions

On first run, macOS will prompt for two permissions. Both are required:

- **Screen Recording** — needed to capture and stream the screen
- **Accessibility** — needed to simulate mouse events in other applications

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--fps` / `-f` | 25 | Target frames per second |
| `--quality` / `-q` | 50 | JPEG quality (1-95) |
| `--width` / `-w` | 0 | Stream width in pixels, 0 = native |
| `--port` / `-p` | 8080 | Server port |

Example:

```bash
./csir --fps 30 --quality 60 --width 1920
```

This version should support 60fps and look crisp like bacon.
