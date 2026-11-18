package com.maba.upscalertest;

/**
 * GPU-only frame timing via EXT_disjoint_timer_query (through JNI; the Android Java bindings
 * do not expose these entry points). Present-to-present time cannot see GPU headroom under
 * vsync; this can.
 */
public final class GpuTimer {
    public boolean supported;
    /** Latest GPU frame time in ms; 0 while warming up; -1 if timestamps are frame-granular. */
    public float gpuMs;

    /** True when gpuMs is a real per-frame GPU measurement. */
    public boolean usable() { return supported && gpuMs > 0f; }

    public void init() {
        gpuMs = 0f;
        supported = MabaNative.available() && MabaNative.timerSupported();
    }

    public void begin() {
        if (supported) MabaNative.timerBegin();
    }

    public void end() {
        if (supported) gpuMs = MabaNative.timerEnd();
    }
}