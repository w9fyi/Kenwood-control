/*  WDSPWrapper.c
 *
 *  C glue layer between Swift and WDSP EMNR/ANR.
 *
 *  WDSP uses complex (IQ) double buffers: buf[2*i]=I, buf[2*i+1]=Q.
 *  For real mono audio we set Q=0.
 *  xemnr/xanr both read from and write to the same buffer (in-place).
 */

/* comm.h must come first — it includes fftw3.h and type definitions
 * needed by emnr.h (fftw_plan) and anr.h */
#include "comm.h"
#include "WDSPWrapper.h"

/* Required global — stubs on macOS (no-op CRITICAL_SECTIONs) */
CH ch[MAX_CHANNELS];

/* ---- EMNR ---- */

struct WDSP_EMNR {
    EMNR   impl;        /* WDSP EMNR object */
    double *workBuf;    /* complex IQ buffer: [I0,Q0, I1,Q1, ...], size=2*bufSize */
    int    bufSize;     /* number of IQ pairs per xemnr call (= real samples) */
};

WDSP_EMNR* wdsp_emnr_create(int sampleRate) {
    WDSP_EMNR *ctx = (WDSP_EMNR *)calloc(1, sizeof(WDSP_EMNR));
    if (!ctx) return NULL;

    /* fsize=1920, ovrlp=4, incr=480 → bsize=480 matches LanAudioPipeline's 480-sample frames
     * At 48kHz: 1920/48000 = 40ms window, 25Hz frequency resolution. */
    const int fsize  = 1920;
    const int ovrlp  = 4;
    const int bsize  = fsize / ovrlp;  /* 480 IQ pairs per xemnr call */

    ctx->bufSize = bsize;
    ctx->workBuf = (double *)calloc(2 * bsize, sizeof(double));
    if (!ctx->workBuf) { free(ctx); return NULL; }

    /* create_emnr(run, position, size, in, out, fsize, ovrlp,
                   rate, wintype, gain, gain_method, npe_method, ae_run)
     * in==out → in-place processing */
    ctx->impl = create_emnr(
        1,            /* run: 1=active */
        0,            /* position: 0 */
        bsize,        /* size: IQ pairs per call */
        ctx->workBuf, /* in  (same pointer → in-place) */
        ctx->workBuf, /* out */
        fsize,        /* FFT size */
        ovrlp,        /* overlap factor */
        sampleRate,   /* sample rate */
        0,            /* wintype: 0=Hann */
        1.0,          /* gain */
        2,            /* gain_method: 2 (decision-directed Wiener, same as Thetis) */
        0,            /* npe_method: 0=LambdaD */
        1             /* ae_run: 1=artifact elimination on */
    );
    if (!ctx->impl) { free(ctx->workBuf); free(ctx); return NULL; }
    return ctx;
}

void wdsp_emnr_process(WDSP_EMNR *ctx, float *inOut, int frameCount) {
    int offset = 0;
    while (offset < frameCount) {
        int chunk = frameCount - offset;
        if (chunk > ctx->bufSize) chunk = ctx->bufSize;

        /* Pack float real samples into complex IQ buffer (Q=0) */
        for (int i = 0; i < chunk; i++) {
            ctx->workBuf[2 * i + 0] = (double)inOut[offset + i];
            ctx->workBuf[2 * i + 1] = 0.0;
        }
        /* Zero-pad the remainder if chunk < bufSize */
        for (int i = chunk; i < ctx->bufSize; i++) {
            ctx->workBuf[2 * i + 0] = 0.0;
            ctx->workBuf[2 * i + 1] = 0.0;
        }

        /* Run EMNR (in-place, position=0) */
        xemnr(ctx->impl, 0);

        /* Extract real component back to float */
        for (int i = 0; i < chunk; i++) {
            inOut[offset + i] = (float)ctx->workBuf[2 * i + 0];
        }
        offset += chunk;
    }
}

void wdsp_emnr_destroy(WDSP_EMNR *ctx) {
    if (!ctx) return;
    destroy_emnr(ctx->impl);
    free(ctx->workBuf);
    free(ctx);
}

/* ---- ANR ---- */

struct WDSP_ANR {
    ANR    impl;        /* WDSP ANR object */
    double *workBuf;    /* complex IQ buffer: [I0,Q0, I1,Q1, ...], size=2*bufSize */
    int    bufSize;     /* IQ pairs per xanr call */
};

WDSP_ANR* wdsp_anr_create(int sampleRate) {
    (void)sampleRate;   /* ANR is sample-rate agnostic */

    WDSP_ANR *ctx = (WDSP_ANR *)calloc(1, sizeof(WDSP_ANR));
    if (!ctx) return NULL;

    const int bsize = 480;  /* IQ pairs per xanr call — matches LanAudioPipeline frame size */
    ctx->bufSize = bsize;
    ctx->workBuf = (double *)calloc(2 * bsize, sizeof(double));
    if (!ctx->workBuf) { free(ctx); return NULL; }

    /* create_anr(run, position, buff_size, in_buff, out_buff,
                  dline_size, n_taps, delay, two_mu, gamma,
                  lidx, lidx_min, lidx_max, ngamma, den_mult, lincr, ldecr)
     * Parameters from Thetis RXA.c */
    ctx->impl = create_anr(
        1,            /* run */
        0,            /* position */
        bsize,        /* buff_size: IQ pairs */
        ctx->workBuf, /* in_buff (in-place) */
        ctx->workBuf, /* out_buff */
        ANR_DLINE_SIZE, /* dline_size: 2048 */
        64,           /* n_taps */
        16,           /* delay */
        0.0001,       /* two_mu (= 2 * step size μ) */
        0.1,          /* gamma (leakage factor) */
        120.0,        /* lidx (initial dynamic leakage index) */
        120.0,        /* lidx_min */
        200.0,        /* lidx_max */
        0.001,        /* ngamma */
        6.25e-10,     /* den_mult */
        1.0,          /* lincr */
        3.0           /* ldecr */
    );
    if (!ctx->impl) { free(ctx->workBuf); free(ctx); return NULL; }
    return ctx;
}

void wdsp_anr_process(WDSP_ANR *ctx, float *inOut, int frameCount) {
    int offset = 0;
    while (offset < frameCount) {
        int chunk = frameCount - offset;
        if (chunk > ctx->bufSize) chunk = ctx->bufSize;

        for (int i = 0; i < chunk; i++) {
            ctx->workBuf[2 * i + 0] = (double)inOut[offset + i];
            ctx->workBuf[2 * i + 1] = 0.0;
        }
        for (int i = chunk; i < ctx->bufSize; i++) {
            ctx->workBuf[2 * i + 0] = 0.0;
            ctx->workBuf[2 * i + 1] = 0.0;
        }

        xanr(ctx->impl, 0);

        for (int i = 0; i < chunk; i++) {
            inOut[offset + i] = (float)ctx->workBuf[2 * i + 0];
        }
        offset += chunk;
    }
}

void wdsp_anr_destroy(WDSP_ANR *ctx) {
    if (!ctx) return;
    destroy_anr(ctx->impl);
    free(ctx->workBuf);
    free(ctx);
}
