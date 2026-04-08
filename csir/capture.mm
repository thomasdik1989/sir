#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>

#include <os/lock.h>
#include "capture.h"

// ---------------------------------------------------------------------------
// Internal ObjC class (not exposed in header)
// ---------------------------------------------------------------------------
@interface ScreenCapture : NSObject <SCStreamOutput, SCStreamDelegate>
- (void)startWithWidth:(int)width fps:(int)fps quality:(float)quality;
- (void)stop;
@end

// Shared frame buffer (file-scoped, accessed via C API and ObjC class)
static os_unfair_lock g_lock_storage = OS_UNFAIR_LOCK_INIT;
static NSData *g_latestJPEG = nil;
static uint64_t g_seq = 0;
static ScreenCapture *g_instance = nil;

static void g_lock_lock(void)   { os_unfair_lock_lock(&g_lock_storage); }
static void g_lock_unlock(void) { os_unfair_lock_unlock(&g_lock_storage); }

@implementation ScreenCapture {
    SCStream *_stream;
    dispatch_queue_t _captureQueue;
    CIContext *_ciContext;
    float _quality;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [NSApplication sharedApplication];
        _captureQueue = dispatch_queue_create("lsc.capture", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _quality = 0.5f;
    }
    return self;
}

- (void)startWithWidth:(int)width fps:(int)fps quality:(float)quality {
    _quality = quality;

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                              onScreenWindowsOnly:YES
                                                completionHandler:^(SCShareableContent *content,
                                                                    NSError *error) {
        if (error || content.displays.count == 0) {
            fprintf(stderr, "Error: failed to get shareable content: %s\n",
                    error ? error.localizedDescription.UTF8String : "no displays found");
            return;
        }

        SCDisplay *display = content.displays.firstObject;
        CGFloat scale = NSScreen.mainScreen ? NSScreen.mainScreen.backingScaleFactor : 2.0;
        int nativeW = (int)(display.width * scale);
        int nativeH = (int)(display.height * scale);

        int outW, outH;
        if (width > 0 && width < nativeW) {
            outW = width;
            outH = (int)(nativeH * ((float)width / nativeW));
        } else {
            outW = nativeW;
            outH = nativeH;
        }

        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = outW;
        config.height = outH;
        config.minimumFrameInterval = CMTimeMake(1, fps);
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.showsCursor = YES;
        config.queueDepth = 3;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                         excludingWindows:@[]];

        self->_stream = [[SCStream alloc] initWithFilter:filter
                                           configuration:config
                                                delegate:self];

        NSError *addErr;
        [self->_stream addStreamOutput:self
                                  type:SCStreamOutputTypeScreen
                    sampleHandlerQueue:self->_captureQueue
                                 error:&addErr];
        if (addErr) {
            fprintf(stderr, "Error: addStreamOutput failed: %s\n",
                    addErr.localizedDescription.UTF8String);
            return;
        }

        [self->_stream startCaptureWithCompletionHandler:^(NSError *startErr) {
            if (startErr) {
                fprintf(stderr, "Error: startCapture failed: %s\n",
                        startErr.localizedDescription.UTF8String);
            } else {
                fprintf(stdout, "  Capture started (%dx%d @ %d FPS, quality %.0f%%)\n",
                        outW, outH, fps, quality * 100.0f);
                fflush(stdout);
            }
        }];
    }];
}

- (void)stop {
    if (!_stream) return;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    _stream = nil;
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImageRef cgImage = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
    if (!cgImage) return;

    NSMutableData *jpegData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpegData,
        CFSTR("public.jpeg"), 1, NULL);

    if (dest) {
        NSDictionary *props = @{
            (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(_quality)
        };
        CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }

    CGImageRelease(cgImage);

    if (jpegData.length > 0) {
        g_lock_lock();
        g_latestJPEG = [jpegData copy];
        g_seq++;
        g_lock_unlock();
    }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr, "Capture stream stopped: %s\n", error.localizedDescription.UTF8String);
}

@end

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------
void capture_start(int width, int fps, float quality) {
    g_instance = [[ScreenCapture alloc] init];
    [g_instance startWithWidth:width fps:fps quality:quality];
}

void capture_stop(void) {
    [g_instance stop];
    g_instance = nil;
}

uint64_t capture_frame_sequence(void) {
    os_unfair_lock_lock(&g_lock_storage);
    uint64_t s = g_seq;
    os_unfair_lock_unlock(&g_lock_storage);
    return s;
}

const void *capture_frame_lock(size_t *out_len) {
    os_unfair_lock_lock(&g_lock_storage);
    if (!g_latestJPEG || g_latestJPEG.length == 0) {
        os_unfair_lock_unlock(&g_lock_storage);
        return NULL;
    }
    *out_len = g_latestJPEG.length;
    return g_latestJPEG.bytes;
}

void capture_frame_release(void) {
    os_unfair_lock_unlock(&g_lock_storage);
}
