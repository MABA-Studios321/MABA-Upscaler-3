/* MABA Upscaler test app - JNI bridge.
 *
 * Runs the REAL maba_upscaler.h controller on-device (not a port) and exposes
 * EXT_disjoint_timer_query GPU timing, which the Android Java bindings lack.
 *
 * Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#define GL_GLEXT_PROTOTYPES 1
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include "../../../src/maba_upscaler.h"
#include "../../../src/maba_framegen.h"

#define JNI(name) Java_com_maba_upscalertest_MabaNative_##name

/* ---- Controller (the actual C header) ---- */

JNIEXPORT jlong JNICALL JNI(ctrlCreate)(JNIEnv* env, jclass cls, jint mode, jfloat fps)
{
    MabaUpscaler* u = (MabaUpscaler*)malloc(sizeof(MabaUpscaler));
    if (!u) return 0;   /* Java side treats 0 as "no native controller" */
    MabaInit(u, (MabaMode)mode, fps);
    return (jlong)(intptr_t)u;
}

JNIEXPORT void JNICALL JNI(ctrlDestroy)(JNIEnv* env, jclass cls, jlong p)
{
    free((void*)(intptr_t)p);
}

/* Returns the rung the mode starts at (Dynamic starts inside the configured range). */
JNIEXPORT jint JNICALL JNI(ctrlSetMode)(JNIEnv* env, jclass cls, jlong p, jint mode)
{
    MabaUpscaler* u = (MabaUpscaler*)(intptr_t)p;
    if (!u) return MABA_DYN_START_RUNG;
    MabaSetMode(u, (MabaMode)mode);
    return u->rung;
}

JNIEXPORT void JNICALL JNI(ctrlSetTargetFps)(JNIEnv* env, jclass cls, jlong p, jfloat fps)
{
    if (p) MabaSetTargetFps((MabaUpscaler*)(intptr_t)p, fps);
}

/* Restricts Dynamic mode to [minScale, maxScale]; returns the rung after clamping. */
JNIEXPORT jint JNICALL JNI(ctrlSetScaleRange)(JNIEnv* env, jclass cls, jlong p, jfloat minScale, jfloat maxScale)
{
    MabaUpscaler* u = (MabaUpscaler*)(intptr_t)p;
    if (!u) return MABA_DYN_START_RUNG;
    MabaSetScaleRange(u, minScale, maxScale);
    return u->rung;
}

/* Returns the rung; outFrame = {renderWidth, renderHeight, qualityShader}. */
JNIEXPORT jint JNICALL JNI(ctrlBeginFrame)(JNIEnv* env, jclass cls, jlong p, jfloat ms,
                                           jint outW, jint outH, jintArray outFrame)
{
    if (!p) return MABA_DYN_START_RUNG;
    MabaFrame f = MabaBeginFrameGpu((MabaUpscaler*)(intptr_t)p, ms, outW, outH);
    jint vals[3] = { f.renderWidth, f.renderHeight, f.qualityShader };
    (*env)->SetIntArrayRegion(env, outFrame, 0, 3, vals);
    return f.rung;
}

/* ---- MABA Frame Gen: the real slot policy and honest counters from maba_framegen.h ---- */

JNIEXPORT jlong JNICALL JNI(fgCreate)(JNIEnv* env, jclass cls)
{
    MabaFrameGen* g = (MabaFrameGen*)malloc(sizeof(MabaFrameGen));
    if (!g) return 0;
    MabaFgInit(g);
    return (jlong)(intptr_t)g;
}

JNIEXPORT void JNICALL JNI(fgDestroy)(JNIEnv* env, jclass cls, jlong p)
{
    free((void*)(intptr_t)p);
}

JNIEXPORT void JNICALL JNI(fgSetEnabled)(JNIEnv* env, jclass cls, jlong p, jint enabled)
{
    if (p) MabaFgSetEnabled((MabaFrameGen*)(intptr_t)p, enabled);
}

/* 1 = 2x (default), 2 = 3x. */
JNIEXPORT void JNICALL JNI(fgSetGenPerReal)(JNIEnv* env, jclass cls, jlong p, jint n)
{
    if (p) MabaFgSetGenPerReal((MabaFrameGen*)(intptr_t)p, n);
}

/* Prediction offset of the generated frame about to be produced (0.5 at 2x; 1/3, 2/3 at 3x). */
JNIEXPORT jfloat JNICALL JNI(fgGenOffset)(JNIEnv* env, jclass cls, jlong p)
{
    return p ? MabaFgGenOffset((const MabaFrameGen*)(intptr_t)p) : 0.5f;
}

JNIEXPORT void JNICALL JNI(fgInvalidate)(JNIEnv* env, jclass cls, jlong p)
{
    if (p) MabaFgInvalidate((MabaFrameGen*)(intptr_t)p);
}

/* 0 = produce a real frame, 1 = produce a generated frame. */
JNIEXPORT jint JNICALL JNI(fgNextSlot)(JNIEnv* env, jclass cls, jlong p)
{
    return p ? (jint)MabaFgNextSlot((MabaFrameGen*)(intptr_t)p) : 0;
}

/* Returns 1 when a one-second counting window just completed. */
JNIEXPORT jint JNICALL JNI(fgPresented)(JNIEnv* env, jclass cls, jlong p, jint slot, jdouble nowMs)
{
    if (!p) return 0;
    return MabaFgPresented((MabaFrameGen*)(intptr_t)p, (MabaFgSlot)slot, (double)nowMs);
}

/* out = {realFps, generatedFps, displayedFps}; returns 1 once a full window has completed. */
JNIEXPORT jint JNICALL JNI(fgStats)(JNIEnv* env, jclass cls, jlong p, jfloatArray out)
{
    MabaFrameGen* g = (MabaFrameGen*)(intptr_t)p;
    jfloat vals[3];
    if (!g) return 0;
    vals[0] = g->realFps;
    vals[1] = g->generatedFps;
    vals[2] = g->displayedFps;
    (*env)->SetFloatArrayRegion(env, out, 0, 3, vals);
    return g->statsValid;
}

/* ---- Frame Gen governor (maba_framegen.h) ---- */

JNIEXPORT jlong JNICALL JNI(govCreate)(JNIEnv* env, jclass cls, jfloat panelHz)
{
    MabaFgGovernor* v = (MabaFgGovernor*)malloc(sizeof(MabaFgGovernor));
    if (!v) return 0;
    MabaFgGovInit(v, panelHz);
    return (jlong)(intptr_t)v;
}

JNIEXPORT void JNICALL JNI(govDestroy)(JNIEnv* env, jclass cls, jlong p) { free((void*)(intptr_t)p); }

JNIEXPORT jint JNICALL JNI(govStep)(JNIEnv* env, jclass cls, jlong p, jfloat intervalMs)
{
    return p ? MabaFgGovStep((MabaFgGovernor*)(intptr_t)p, intervalMs) : 1;
}

/* out = {phase, onMs, offMs}; */
JNIEXPORT void JNICALL JNI(govInfo)(JNIEnv* env, jclass cls, jlong p, jfloatArray out)
{
    MabaFgGovernor* v = (MabaFgGovernor*)(intptr_t)p;
    jfloat vals[3];
    if (!v) return;
    vals[0] = (jfloat)v->phase; vals[1] = v->onMs; vals[2] = v->offMs;
    (*env)->SetFloatArrayRegion(env, out, 0, 3, vals);
}
/* ---- GPU timer (EXT_disjoint_timer_query) ---- */

#define RING 3
#define ZERO_FRAMES_UNUSABLE 8   /* begin == end this many times: timer is frame-granular */
static GLuint qBegin[RING], qEnd[RING];
static int queriesCreated;   /* the ring holds query objects that were generated and not yet deleted */
static int timerFrame;
static int timerSupported = -1;
static float lastGpuMs;
static int zeroFrames;   /* frames whose begin and end timestamps were identical */

JNIEXPORT jboolean JNICALL JNI(timerSupported)(JNIEnv* env, jclass cls)
{
    /* Called once per GL context (onSurfaceCreated). Query objects belong to the context, so
       after a context loss they are created again rather than reused. */
    const char* ext = (const char*)glGetString(GL_EXTENSIONS);
    timerSupported = ext && strstr(ext, "GL_EXT_disjoint_timer_query") ? 1 : 0;
    timerFrame = 0;
    lastGpuMs = 0.0f;
    zeroFrames = 0;
    if (queriesCreated) {
        /* Seen again after a surface re-creation: when the context survived, the old ring is still
           alive and must be released, or it leaks. When the context was lost, its names mean
           nothing here and glDeleteQueries ignores names that are not queries. */
        GLuint old[RING * 2];
        for (int i = 0; i < RING; i++) { old[i * 2] = qBegin[i]; old[i * 2 + 1] = qEnd[i]; }
        glDeleteQueriesEXT(RING * 2, old);
        queriesCreated = 0;
    }
    if (timerSupported) {
        GLuint all[RING * 2];
        glGenQueriesEXT(RING * 2, all);
        for (int i = 0; i < RING; i++) { qBegin[i] = all[i * 2]; qEnd[i] = all[i * 2 + 1]; }
        queriesCreated = 1;
    }
    return timerSupported ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL JNI(timerBegin)(JNIEnv* env, jclass cls)
{
    if (timerSupported != 1 || zeroFrames >= ZERO_FRAMES_UNUSABLE) return;
    glQueryCounterEXT(qBegin[timerFrame % RING], GL_TIMESTAMP_EXT);
}

JNIEXPORT jfloat JNICALL JNI(timerEnd)(JNIEnv* env, jclass cls)
{
    if (timerSupported != 1) return 0.0f;
    if (zeroFrames >= ZERO_FRAMES_UNUSABLE) return -1.0f;   /* known unusable: no more queries */
    glQueryCounterEXT(qEnd[timerFrame % RING], GL_TIMESTAMP_EXT);
    int old = (timerFrame + 1) % RING;
    GLint available = 0;
    /* The oldest ring slot has only been issued once RING - 1 frames have gone by. */
    if (timerFrame >= RING - 1)
        glGetQueryObjectivEXT(qEnd[old], GL_QUERY_RESULT_AVAILABLE_EXT, &available);
    if (available) {
        GLuint64 b = 0, e = 0;
        glGetQueryObjectui64vEXT(qBegin[old], GL_QUERY_RESULT_EXT, &b);
        glGetQueryObjectui64vEXT(qEnd[old], GL_QUERY_RESULT_EXT, &e);
        GLint disjoint = 0;
        glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
        if (!disjoint) {
            /* Some drivers (Mali-G52 r49) latch timestamps once per frame, so begin == end and
               the occasional non-zero reading is just one vsync interval. Such a timer cannot
               measure GPU time; after ZERO_FRAMES_UNUSABLE such frames report it as unusable. */
            if (e == b) zeroFrames++;
            else lastGpuMs = (float)((double)(e - b) / 1e6);
        }
    }
    timerFrame++;
    return zeroFrames >= ZERO_FRAMES_UNUSABLE ? -1.0f : lastGpuMs;
}

/* ---- Frame timestamps (EGL_ANDROID_get_frame_timestamps): when each presented frame really reached the glass ----
 * Used by the input-latency probe. Both calls must come from the render thread, with the window surface current.
 * Times are CLOCK_MONOTONIC nanoseconds, the same clock as System.nanoTime() and MotionEvent.getEventTime(). */

static PFNEGLGETNEXTFRAMEIDANDROIDPROC gGetNextFrameId;
static PFNEGLGETFRAMETIMESTAMPSANDROIDPROC gGetFrameTimestamps;

JNIEXPORT jint JNICALL JNI(latEnable)(JNIEnv* env, jclass cls)
{
    EGLDisplay dpy = eglGetCurrentDisplay();
    EGLSurface surf = eglGetCurrentSurface(EGL_DRAW);
    gGetNextFrameId = (PFNEGLGETNEXTFRAMEIDANDROIDPROC)eglGetProcAddress("eglGetNextFrameIdANDROID");
    gGetFrameTimestamps = (PFNEGLGETFRAMETIMESTAMPSANDROIDPROC)eglGetProcAddress("eglGetFrameTimestampsANDROID");
    if (!gGetNextFrameId || !gGetFrameTimestamps || dpy == EGL_NO_DISPLAY || surf == EGL_NO_SURFACE) return 0;
    return eglSurfaceAttrib(dpy, surf, EGL_TIMESTAMPS_ANDROID, EGL_TRUE) ? 1 : 0;
}

/* The id the NEXT eglSwapBuffers will get, or -1. */
JNIEXPORT jlong JNICALL JNI(latNextFrameId)(JNIEnv* env, jclass cls)
{
    EGLuint64KHR id = 0;
    if (!gGetNextFrameId) return -1;
    if (!gGetNextFrameId(eglGetCurrentDisplay(), eglGetCurrentSurface(EGL_DRAW), &id)) return -1;
    return (jlong)id;
}

/* out[0..3] = requested present, rendering complete, composition latch, display present (ns). Returns 1 when the display
 * present time is known; any other value that is still pending or not recorded is <= 0. */
JNIEXPORT jint JNICALL JNI(latQuery)(JNIEnv* env, jclass cls, jlong frameId, jlongArray out)
{
    static const EGLint names[4] = { EGL_REQUESTED_PRESENT_TIME_ANDROID, EGL_RENDERING_COMPLETE_TIME_ANDROID,
                                     EGL_COMPOSITION_LATCH_TIME_ANDROID, EGL_DISPLAY_PRESENT_TIME_ANDROID };
    EGLnsecsANDROID values[4] = { 0, 0, 0, 0 };
    jlong res[4];
    int i, ok;
    if (!gGetFrameTimestamps || frameId < 0) return 0;
    if (!gGetFrameTimestamps(eglGetCurrentDisplay(), eglGetCurrentSurface(EGL_DRAW), (EGLuint64KHR)frameId, 4, names, values)) return 0;
    for (i = 0; i < 4; i++) {
        res[i] = (jlong)values[i];   /* pending (-2), invalid (-1) or not recorded (0) are passed through */
    }
    ok = values[3] > 0;
    (*env)->SetLongArrayRegion(env, out, 0, 4, res);
    return ok;
}