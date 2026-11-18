package com.maba.upscalertest;

/** JNI bridge to the real C controller (maba_upscaler.h) and EXT_disjoint_timer_query. */
public final class MabaNative {
    private static boolean loaded;

    static {
        try {
            System.loadLibrary("maba_jni");
            loaded = true;
        } catch (UnsatisfiedLinkError e) {
            loaded = false;
        }
    }

    public static boolean available() { return loaded; }

    public static native long ctrlCreate(int mode, float fps);
    public static native void ctrlDestroy(long ptr);
    /** Returns the rung the mode starts at. */
    public static native int ctrlSetMode(long ptr, int mode);
    public static native void ctrlSetTargetFps(long ptr, float fps);
    /** Restricts Dynamic mode to a render-scale range; returns the (possibly clamped) rung. */
    public static native int ctrlSetScaleRange(long ptr, float minScale, float maxScale);
    /** Returns rung; outFrame = {renderWidth, renderHeight, qualityShader}. */
    public static native int ctrlBeginFrame(long ptr, float ms, int outW, int outH, int[] outFrame);

    /** MABA Frame Gen (maba_framegen.h): slot policy and honest one-second counters. */
    public static native long fgCreate();
    public static native void fgDestroy(long ptr);
    public static native void fgSetEnabled(long ptr, int enabled);
    public static native void fgInvalidate(long ptr);
    /** 0 = produce a real frame, 1 = produce a generated frame. */
    public static native int fgNextSlot(long ptr);
    public static native void fgSetGenPerReal(long ptr, int n);
    public static native float fgGenOffset(long ptr);
    /** Returns 1 when a one-second counting window just completed. */
    public static native int fgPresented(long ptr, int slot, double nowMs);
    /** out = {realFps, generatedFps, displayedFps}; returns 1 once a full window has completed. */
    public static native int fgStats(long ptr, float[] out);


    /** Frame Gen governor: keeps Frame Gen on only while it shows more frames per second than off. */
    public static native long govCreate(float panelHz);
    public static native void govDestroy(long ptr);
    /** Call once per real frame with the interval since the previous one; returns 1 when Frame Gen should run. */
    public static native int govStep(long ptr, float intervalMs);
    /** out = {phase (0 on, 1 probing off, 2 off, 3 probing on), onMs, offMs}. */
    public static native void govInfo(long ptr, float[] out);

    public static native boolean timerSupported();
    public static native void timerBegin();
    /** Latest GPU frame time in ms; 0 while warming up; -1 if the driver's timestamps are
     *  frame-granular and cannot measure GPU time. */
    public static native float timerEnd();

    // Frame timestamps for the input-latency probe (render thread only).
    public static native int latEnable();
    public static native long latNextFrameId();
    public static native int latQuery(long frameId, long[] out);
}