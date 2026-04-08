#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void capture_start(int width, int fps, float quality);
void capture_stop(void);
uint64_t capture_frame_sequence(void);

// Returns pointer to JPEG data and sets *out_len. Caller must call
// capture_frame_release() when done. Returns NULL if no frame available.
const void *capture_frame_lock(size_t *out_len);
void capture_frame_release(void);

#ifdef __cplusplus
}
#endif
