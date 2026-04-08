#include <libwebsockets.h>

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <getopt.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <vector>
#include <algorithm>

#import "capture.h"

// ---------------------------------------------------------------------------
// Embedded HTML (same as ../index.html)
// ---------------------------------------------------------------------------
static const char INDEX_HTML[] = R"html(<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>Drawing Relay</title>
<style>
  * { margin: 0; padding: 0; }
  html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
  #screen {
    width: 100%;
    height: 100%;
    object-fit: contain;
    touch-action: none;
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    user-select: none;
  }
  #status {
    position: fixed;
    top: 8px;
    left: 8px;
    color: #fff;
    font: 14px monospace;
    background: rgba(0,0,0,0.6);
    padding: 4px 8px;
    border-radius: 4px;
    pointer-events: none;
    z-index: 10;
  }
</style>
</head>
<body>
<div id="status">Connecting...</div>
<img id="screen" src="" alt="">
<script>
const host = location.host;
const statusEl = document.getElementById('status');
const screenEl = document.getElementById('screen');
let prevBlob = null;

function connectScreen() {
  const ws = new WebSocket(`ws://${host}/ws/screen`);
  ws.binaryType = 'blob';
  ws.onmessage = (e) => {
    if (prevBlob) URL.revokeObjectURL(prevBlob);
    const url = URL.createObjectURL(e.data);
    screenEl.src = url;
    prevBlob = url;
  };
  ws.onopen = () => { statusEl.textContent = 'Connected'; };
  ws.onclose = () => {
    statusEl.textContent = 'Disconnected - reconnecting...';
    setTimeout(connectScreen, 1000);
  };
}

function connectInput() {
  const ws = new WebSocket(`ws://${host}/ws/input`);
  let active = false;
  let lastMoveTime = 0;
  const MOVE_THROTTLE_MS = 8;

  function send(type, touch) {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (type === 'move') {
      const now = performance.now();
      if (now - lastMoveTime < MOVE_THROTTLE_MS) return;
      lastMoveTime = now;
    }
    const rect = screenEl.getBoundingClientRect();
    const x = (touch.clientX - rect.left) / rect.width;
    const y = (touch.clientY - rect.top) / rect.height;
    ws.send(JSON.stringify({
      type,
      x: Math.max(0, Math.min(1, x)),
      y: Math.max(0, Math.min(1, y))
    }));
  }

  screenEl.addEventListener('touchstart', (e) => {
    e.preventDefault();
    active = true;
    send('start', e.touches[0]);
  }, { passive: false });

  screenEl.addEventListener('touchmove', (e) => {
    e.preventDefault();
    if (active) send('move', e.touches[0]);
  }, { passive: false });

  screenEl.addEventListener('touchend', (e) => {
    e.preventDefault();
    if (active) {
      send('end', e.changedTouches[0]);
      active = false;
    }
  }, { passive: false });

  screenEl.addEventListener('touchcancel', (e) => {
    e.preventDefault();
    if (active) {
      send('end', e.changedTouches[0]);
      active = false;
    }
  }, { passive: false });

  ws.onclose = () => { setTimeout(connectInput, 1000); };
}

connectScreen();
connectInput();
</script>
</body>
</html>)html";

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------
static int g_screen_w = 0, g_screen_h = 0;
static volatile int g_interrupted = 0;
static std::vector<struct lws *> g_screen_clients;
static uint64_t g_lastCheckedSeq = 0;

// ---------------------------------------------------------------------------
// Mouse simulation via CGEvent
// ---------------------------------------------------------------------------
static void simulateMouse(CGEventType type, double x, double y) {
    CGPoint point = CGPointMake(x, y);
    if (type == kCGEventLeftMouseDown) {
        CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                                  point, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, move);
        CFRelease(move);
    }
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

// ---------------------------------------------------------------------------
// Networking helpers
// ---------------------------------------------------------------------------
static const char *getLocalIP() {
    static char ip[INET_ADDRSTRLEN] = "127.0.0.1";
    struct ifaddrs *ifaddr;
    if (getifaddrs(&ifaddr) == -1) return ip;

    for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(ifa->ifa_name, "lo0") == 0) continue;
        struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
        inet_ntop(AF_INET, &addr->sin_addr, ip, sizeof(ip));
        if (strncmp(ip, "127.", 4) != 0) break;
    }
    freeifaddrs(ifaddr);
    return ip;
}

// ---------------------------------------------------------------------------
// libwebsockets callback
// ---------------------------------------------------------------------------
enum ConnType { CONN_HTTP = 0, CONN_INPUT, CONN_SCREEN };

struct PerSessionData {
    ConnType type;
    bool mouseDown;
    double lastX, lastY;
    uint64_t lastSentSeq;
};

static int callback_lsc(struct lws *wsi, enum lws_callback_reasons reason,
                         void *user, void *in, size_t len) {
    auto *psd = static_cast<PerSessionData *>(user);

    switch (reason) {

    // ── HTTP: serve index.html ──────────────────────────────────────────
    case LWS_CALLBACK_HTTP: {
        psd->type = CONN_HTTP;
        size_t html_len = strlen(INDEX_HTML);

        uint8_t hdrbuf[LWS_PRE + 512];
        uint8_t *start = hdrbuf + LWS_PRE, *p = start;
        uint8_t *end_ptr = hdrbuf + sizeof(hdrbuf) - 1;

        if (lws_add_http_header_status(wsi, HTTP_STATUS_OK, &p, end_ptr) ||
            lws_add_http_header_by_token(wsi, WSI_TOKEN_HTTP_CONTENT_TYPE,
                (const uint8_t *)"text/html", 9, &p, end_ptr) ||
            lws_add_http_header_content_length(wsi, (lws_filepos_t)html_len,
                &p, end_ptr) ||
            lws_finalize_http_header(wsi, &p, end_ptr))
            return 1;

        lws_write(wsi, start, (size_t)(p - start), LWS_WRITE_HTTP_HEADERS);
        lws_callback_on_writable(wsi);
        return 0;
    }

    case LWS_CALLBACK_HTTP_WRITEABLE: {
        if (psd->type != CONN_HTTP) break;
        size_t html_len = strlen(INDEX_HTML);
        auto *buf = static_cast<uint8_t *>(malloc(LWS_PRE + html_len));
        memcpy(buf + LWS_PRE, INDEX_HTML, html_len);
        lws_write(wsi, buf + LWS_PRE, html_len, LWS_WRITE_HTTP);
        free(buf);
        if (lws_http_transaction_completed(wsi)) return -1;
        return 0;
    }

    // ── WebSocket: connection lifecycle ─────────────────────────────────
    case LWS_CALLBACK_ESTABLISHED: {
        char path[64] = {};
        lws_hdr_copy(wsi, path, sizeof(path), WSI_TOKEN_GET_URI);

        if (strcmp(path, "/ws/input") == 0) {
            psd->type = CONN_INPUT;
            psd->mouseDown = false;
            fprintf(stdout, "Input client connected (screen: %dx%d)\n",
                    g_screen_w, g_screen_h);
        } else if (strcmp(path, "/ws/screen") == 0) {
            psd->type = CONN_SCREEN;
            psd->lastSentSeq = 0;
            g_screen_clients.push_back(wsi);
            fprintf(stdout, "Screen client connected\n");
        }
        fflush(stdout);
        break;
    }

    case LWS_CALLBACK_CLOSED: {
        if (psd->type == CONN_INPUT) {
            if (psd->mouseDown) {
                simulateMouse(kCGEventLeftMouseUp, psd->lastX, psd->lastY);
                fprintf(stdout, "Released stuck mouse button on disconnect\n");
            }
            fprintf(stdout, "Input client disconnected\n");
        } else if (psd->type == CONN_SCREEN) {
            g_screen_clients.erase(
                std::remove(g_screen_clients.begin(), g_screen_clients.end(), wsi),
                g_screen_clients.end());
            fprintf(stdout, "Screen client disconnected\n");
        }
        fflush(stdout);
        break;
    }

    // ── WebSocket: receive touch input ──────────────────────────────────
    case LWS_CALLBACK_RECEIVE: {
        if (psd->type != CONN_INPUT || !in || len == 0) break;
        @autoreleasepool {
            NSData *jsonData = [NSData dataWithBytesNoCopy:in length:len freeWhenDone:NO];
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                options:0
                                                                  error:nil];
            if (!dict) break;

            NSString *evtype = dict[@"type"];
            double x = [dict[@"x"] doubleValue] * g_screen_w;
            double y = [dict[@"y"] doubleValue] * g_screen_h;
            psd->lastX = x;
            psd->lastY = y;

            if ([evtype isEqualToString:@"start"]) {
                if (psd->mouseDown)
                    simulateMouse(kCGEventLeftMouseUp, x, y);
                simulateMouse(kCGEventLeftMouseDown, x, y);
                psd->mouseDown = true;
            } else if ([evtype isEqualToString:@"move"] && psd->mouseDown) {
                simulateMouse(kCGEventLeftMouseDragged, x, y);
            } else if ([evtype isEqualToString:@"end"]) {
                if (psd->mouseDown) {
                    simulateMouse(kCGEventLeftMouseUp, x, y);
                    psd->mouseDown = false;
                }
            }
        }
        break;
    }

    // ── WebSocket: send screen frame ────────────────────────────────────
    case LWS_CALLBACK_SERVER_WRITEABLE: {
        if (psd->type != CONN_SCREEN) break;
        uint64_t seq = capture_frame_sequence();
        if (seq == 0 || seq == psd->lastSentSeq) break;

        size_t flen = 0;
        const void *fdata = capture_frame_lock(&flen);
        if (!fdata) break;

        auto *buf = static_cast<uint8_t *>(malloc(LWS_PRE + flen));
        memcpy(buf + LWS_PRE, fdata, flen);
        capture_frame_release();

        int n = lws_write(wsi, buf + LWS_PRE, flen, LWS_WRITE_BINARY);
        free(buf);

        if (n < 0) return -1;
        psd->lastSentSeq = seq;
        break;
    }

    default:
        break;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Signal handler
// ---------------------------------------------------------------------------
static void sighandler(int) { g_interrupted = 1; }

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    @autoreleasepool {
        int fps = 25, quality = 50, width = 0, port = 8080;

        static struct option long_opts[] = {
            {"fps",     required_argument, nullptr, 'f'},
            {"quality", required_argument, nullptr, 'q'},
            {"width",   required_argument, nullptr, 'w'},
            {"port",    required_argument, nullptr, 'p'},
            {nullptr, 0, nullptr, 0}
        };
        int c;
        while ((c = getopt_long(argc, argv, "f:q:w:p:", long_opts, nullptr)) != -1) {
            switch (c) {
                case 'f': fps = atoi(optarg); break;
                case 'q': quality = atoi(optarg); break;
                case 'w': width = atoi(optarg); break;
                case 'p': port = atoi(optarg); break;
            }
        }

        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        g_screen_w = (int)mainBounds.size.width;
        g_screen_h = (int)mainBounds.size.height;

        capture_start(width, fps, (float)quality / 100.0f);

        signal(SIGINT, sighandler);
        signal(SIGTERM, sighandler);

        struct lws_protocols protocols[] = {
            {"lsc", callback_lsc, sizeof(PerSessionData), 4096, 0, nullptr, 0},
            {nullptr, nullptr, 0, 0, 0, nullptr, 0}
        };

        struct lws_context_creation_info info;
        memset(&info, 0, sizeof(info));
        info.port = port;
        info.protocols = protocols;
        info.gid = -1;
        info.uid = -1;

        struct lws_context *context = lws_create_context(&info);
        if (!context) {
            fprintf(stderr, "Error: failed to create lws context\n");
            return 1;
        }

        const char *ip = getLocalIP();
        fprintf(stdout, "\n  Open on iPad:  http://%s:%d\n\n", ip, port);
        fprintf(stdout, "  FPS: %d  |  Quality: %d  |  Width: %dpx\n\n",
                fps, quality, width);
        fflush(stdout);

        int interval_ms = 1000 / fps;
        while (!g_interrupted) {
            lws_service(context, interval_ms);

            uint64_t currentSeq = capture_frame_sequence();
            if (currentSeq > g_lastCheckedSeq) {
                for (auto *wsi : g_screen_clients)
                    lws_callback_on_writable(wsi);
                g_lastCheckedSeq = currentSeq;
            }
        }

        fprintf(stdout, "\nShutting down...\n");
        capture_stop();
        lws_context_destroy(context);
    }
    return 0;
}
