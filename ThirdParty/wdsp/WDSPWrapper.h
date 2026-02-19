/*  WDSPWrapper.h
 *
 *  Thin C API wrapping WDSP EMNR and ANR for use from Swift.
 *  Handles float↔double conversion and complex-IQ buffer packing.
 *
 *  Both EMNR and ANR internally use complex (IQ) double buffers.
 *  For real mono audio, we pack: in[2*i]=sample, in[2*i+1]=0.
 */

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- EMNR (Enhanced Minimum Noise Reduction) ---- */
/* Uses FFTW overlap-add with Wiener gain + psychoacoustic artifact elimination */
typedef struct WDSP_EMNR WDSP_EMNR;

/* Create an EMNR context.
 * sampleRate: audio sample rate in Hz (e.g. 12000)
 * Returns NULL on allocation failure. */
WDSP_EMNR* wdsp_emnr_create(int sampleRate);

/* Process audio in-place.
 * inOut: float buffer of frameCount samples.
 * Internally chunked to bufSize — all frames are handled correctly. */
void wdsp_emnr_process(WDSP_EMNR* ctx, float* inOut, int frameCount);

void wdsp_emnr_destroy(WDSP_EMNR* ctx);

/* ---- ANR (Adaptive Noise Reduction / LMS) ---- */
/* Time-domain LMS filter with delay line; no FFTW dependency */
typedef struct WDSP_ANR WDSP_ANR;

WDSP_ANR* wdsp_anr_create(int sampleRate);
void      wdsp_anr_process(WDSP_ANR* ctx, float* inOut, int frameCount);
void      wdsp_anr_destroy(WDSP_ANR* ctx);

#ifdef __cplusplus
}
#endif
