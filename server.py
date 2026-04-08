import argparse
import asyncio
import io
import json
import os
import socket
import time
from pathlib import Path

os.environ["PYTHONUNBUFFERED"] = "1"

import Quartz
from aiohttp import web
from PIL import Image


def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def get_screen_size():
    main = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
    return int(main.size.width), int(main.size.height)


def capture_screen(target_width, quality):
    cg_image = Quartz.CGWindowListCreateImage(
        Quartz.CGRectInfinite,
        Quartz.kCGWindowListOptionOnScreenOnly,
        Quartz.kCGNullWindowID,
        Quartz.kCGWindowImageDefault,
    )
    if cg_image is None:
        return None

    w = Quartz.CGImageGetWidth(cg_image)
    h = Quartz.CGImageGetHeight(cg_image)
    bpr = Quartz.CGImageGetBytesPerRow(cg_image)
    data_provider = Quartz.CGImageGetDataProvider(cg_image)
    raw = Quartz.CGDataProviderCopyData(data_provider)

    img = Image.frombytes("RGBA", (w, h), bytes(raw), "raw", "BGRA", bpr, 1)
    if target_width and target_width < w:
        ratio = target_width / w
        img = img.resize((target_width, int(h * ratio)), Image.LANCZOS)

    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def simulate_mouse(event_type, x, y):
    point = Quartz.CGPointMake(x, y)
    if event_type == Quartz.kCGEventLeftMouseDown:
        move = Quartz.CGEventCreateMouseEvent(
            None, Quartz.kCGEventMouseMoved, point, Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
    event = Quartz.CGEventCreateMouseEvent(
        None, event_type, point, Quartz.kCGMouseButtonLeft
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


async def handle_index(request):
    html_path = Path(__file__).parent / "index.html"
    return web.Response(text=html_path.read_text(), content_type="text/html")


async def handle_input_ws(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    screen_w, screen_h = get_screen_size()
    print(f"Input client connected (screen: {screen_w}x{screen_h})")

    mouse_down = False
    last_x, last_y = 0.0, 0.0

    async for msg in ws:
        if msg.type == web.WSMsgType.TEXT:
            data = json.loads(msg.data)
            x = data["x"] * screen_w
            y = data["y"] * screen_h
            last_x, last_y = x, y
            t = data["type"]
            if t == "start":
                if mouse_down:
                    simulate_mouse(Quartz.kCGEventLeftMouseUp, x, y)
                simulate_mouse(Quartz.kCGEventLeftMouseDown, x, y)
                mouse_down = True
            elif t == "move" and mouse_down:
                simulate_mouse(Quartz.kCGEventLeftMouseDragged, x, y)
            elif t == "end":
                if mouse_down:
                    simulate_mouse(Quartz.kCGEventLeftMouseUp, x, y)
                    mouse_down = False

    if mouse_down:
        simulate_mouse(Quartz.kCGEventLeftMouseUp, last_x, last_y)
        print("Released stuck mouse button on disconnect")

    print("Input client disconnected")
    return ws


async def handle_screen_ws(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    app = request.app
    fps = app["fps"]
    base_quality = app["quality"]
    target_width = app["width"]
    frame_budget = 1.0 / fps

    print(f"Screen client connected (target {fps} FPS, quality {base_quality}, width {target_width})")

    quality = base_quality
    try:
        while not ws.closed:
            t0 = time.monotonic()
            frame = await asyncio.get_event_loop().run_in_executor(
                None, capture_screen, target_width, quality
            )
            if frame is None:
                await asyncio.sleep(frame_budget)
                continue

            await ws.send_bytes(frame)

            elapsed = time.monotonic() - t0
            if elapsed > frame_budget and quality > 15:
                quality = max(15, quality - 5)
            elif elapsed < frame_budget * 0.7 and quality < base_quality:
                quality = min(base_quality, quality + 2)

            sleep_time = max(0, frame_budget - elapsed)
            if sleep_time > 0:
                await asyncio.sleep(sleep_time)
    except Exception as e:
        if not ws.closed:
            print(f"Screen stream error: {e}")

    print(f"Screen client disconnected (final quality: {quality})")
    return ws


def main():
    parser = argparse.ArgumentParser(description="iPad Drawing Input Relay")
    parser.add_argument("--fps", type=int, default=25, help="Target FPS for screen mirror (default: 25)")
    parser.add_argument("--quality", type=int, default=50, help="JPEG quality 1-95 (default: 50)")
    parser.add_argument("--width", type=int, default=0, help="Stream width in px, 0 = native resolution (default: 0)")
    parser.add_argument("--port", type=int, default=8080, help="Server port (default: 8080)")
    args = parser.parse_args()

    app = web.Application()
    app["fps"] = args.fps
    app["quality"] = args.quality
    app["width"] = args.width

    app.router.add_get("/", handle_index)
    app.router.add_get("/ws/input", handle_input_ws)
    app.router.add_get("/ws/screen", handle_screen_ws)

    ip = get_local_ip()
    print(f"\n  Open on iPad:  http://{ip}:{args.port}\n", flush=True)
    print(f"  FPS: {args.fps}  |  Quality: {args.quality}  |  Width: {args.width}px\n", flush=True)

    web.run_app(app, host="0.0.0.0", port=args.port, print=None)


if __name__ == "__main__":
    main()
