# Simple Input Relay (or Sir because why not)

Use your iPad/tablet as a wireless drawing tablet for your MacBook. Draws on the iPad are relayed as mouse input to whatever application is in focus on the MacBook (Aseprite, Photoshop, Krita, etc.).

Bear in mind that this is the product of 1 day of searching and tinkering.
Expect bugs, the spanish inquisition, or none of these and have fun drawing :D.

Known issues:
- When opened on a phone most input seems to be a bit off when zoomed in on Asesprite.

## Requirements

- macOS
- Python 3.10+ (via Homebrew: `brew install python`)
- iPad/tablet/phone on the same Wi-Fi network as the MacBook

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Usage

```bash
source .venv/bin/activate
python3 -u server.py
```

The server prints a URL like `http://192.168.x.x:8080`. Open that URL in Safari on your iPad (or another browser on another device).

Open a drawing application on your MacBook, then draw on the iPad screen.

## macOS Permissions

On first run, macOS will prompt for two permissions. Both are required:

- **Screen Recording** — needed to capture and stream the screen to the iPad
- **Accessibility** — needed to simulate mouse events in other applications

If the screen mirror shows the desktop wallpaper but not application windows, go to **System Settings > Privacy & Security > Screen Recording**, toggle the permission for your terminal app off and back on, then restart the server. (if you start the script from for example your IDE like vscode then you need to set the permissions for vscode.)

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--fps` | 25 | Target frames per second for screen mirror |
| `--quality` | 50 | JPEG quality (1-95) |
| `--width` | 0 | Stream width in pixels, 0 = native resolution |
| `--port` | 8080 | Server port |

Example with lower resolution for slower networks:

```bash
python3 -u server.py --width 1920 --quality 60
```
