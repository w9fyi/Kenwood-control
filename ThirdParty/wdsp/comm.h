/*  comm.h — macOS stub for WDSP
 *
 *  Replaces the Windows-specific comm.h from OpenHPSDR-wdsp for macOS builds.
 *  Only the minimal subset required for emnr.c and anr.c is provided.
 *  The SetRXA* DLL-export functions have been removed from our copies of
 *  emnr.c and anr.c, so no RXA channel infrastructure is needed here.
 *
 *  Original comm.h Copyright (C) 2013, 2024, 2025 Warren Pratt, NR0V — GPL v2+
 */
#pragma once

#include <fftw3.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

/* ---- Windows compatibility ---- */

/* __declspec(x) → nothing on macOS */
#ifndef __declspec
#define __declspec(x)
#endif
#define PORT

/* CRITICAL_SECTION — stub as no-op (used only in the removed SetRXA* section) */
typedef struct { int _unused; } CRITICAL_SECTION;
static inline void EnterCriticalSection(CRITICAL_SECTION *cs) { (void)cs; }
static inline void LeaveCriticalSection(CRITICAL_SECTION *cs) { (void)cs; }

/* _aligned_malloc / _aligned_free → POSIX on macOS */
static inline void* _aligned_malloc(size_t size, size_t alignment) {
    void* ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) return NULL;
    return ptr;
}
#define _aligned_free free

/* malloc0: allocate + zero (used throughout WDSP) */
static inline void* malloc0(int size) {
    void* p = NULL;
    if (posix_memalign(&p, 16, (size_t)size) != 0) return NULL;
    memset(p, 0, (size_t)size);
    return p;
}

/* ---- WDSP type definitions ---- */

/* Complex type: 2-element double array [real, imag] */
typedef double complex[2];

/* min/max macros */
#ifndef max
#define max(a,b) ((a)>(b)?(a):(b))
#endif
#ifndef min
#define min(a,b) ((a)<(b)?(a):(b))
#endif

/* Math constants */
#define PI    3.1415926535897932
#define TWOPI 6.2831853071795864

/* mlog10: fast lookup-table log10 in WDSP, stub it as regular log10 */
#ifndef mlog10
#define mlog10(x) log10(x)
#endif

/* Channel infrastructure — required for ch[] global used by WDSPWrapper.c */
#define MAX_CHANNELS 8
typedef struct _ch {
    CRITICAL_SECTION csDSP;
} CH;
extern CH ch[MAX_CHANNELS];

/* Include WDSP headers that emnr.c and anr.c need (in original, comm.h included all WDSP headers) */
#include "anr.h"
#include "emnr.h"
#include "calculus.h"
