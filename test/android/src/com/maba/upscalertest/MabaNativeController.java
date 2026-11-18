package com.maba.upscalertest;

/** The REAL C controller from maba_upscaler.h, running on-device via JNI. */
public final class MabaNativeController implements DynController {
    private long ptr;
    private int rung;
    private int outW = 1541, outH = 720;
    private final int[] frame = new int[3];

    public MabaNativeController(int mode, float targetFps) {
        ptr = MabaNative.ctrlCreate(mode, targetFps);
        rung = MabaController.modeRung(mode);
    }

    public void setOutSize(int w, int h) { outW = w; outH = h; }

    @Override public void setMode(int mode) {
        rung = MabaNative.ctrlSetMode(ptr, mode);
    }

    @Override public void setTargetFps(float fps) {
        MabaNative.ctrlSetTargetFps(ptr, fps);
    }

    @Override public void setScaleRange(float minScale, float maxScale) {
        rung = MabaNative.ctrlSetScaleRange(ptr, minScale, maxScale);
    }

    @Override public void updateDynamic(float frameMs) {
        rung = MabaNative.ctrlBeginFrame(ptr, frameMs, outW, outH, frame);
    }

    @Override public int rung() { return rung; }

    /** Frees the native controller. Safe to call more than once; the GC finaliser calls it too. */
    public synchronized void release() {
        if (ptr != 0) {
            MabaNative.ctrlDestroy(ptr);
            ptr = 0;
        }
    }

    @Override protected void finalize() {
        release();
    }
}
