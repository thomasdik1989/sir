CXX      = clang++
CXXFLAGS = -std=c++17 -O2 -Wall -Wno-deprecated-declarations -fobjc-arc

FRAMEWORKS = -framework ScreenCaptureKit \
             -framework CoreGraphics    \
             -framework CoreMedia       \
             -framework CoreVideo       \
             -framework CoreImage       \
             -framework ImageIO         \
             -framework AppKit          \
             -framework Foundation

LWS_CFLAGS = $(shell pkg-config --cflags libwebsockets 2>/dev/null || echo "-I/opt/homebrew/include")
LWS_LIBS   = $(shell pkg-config --libs   libwebsockets 2>/dev/null || echo "-L/opt/homebrew/lib -lwebsockets")
SSL_CFLAGS = -I$(shell brew --prefix openssl 2>/dev/null || echo /opt/homebrew/opt/openssl)/include

SRCS = main.mm capture.mm
BIN  = csir

$(BIN): $(SRCS) capture.h
	$(CXX) $(CXXFLAGS) $(LWS_CFLAGS) $(SSL_CFLAGS) -o $(BIN) $(SRCS) $(FRAMEWORKS) $(LWS_LIBS)

clean:
	rm -f $(BIN)

.PHONY: clean
