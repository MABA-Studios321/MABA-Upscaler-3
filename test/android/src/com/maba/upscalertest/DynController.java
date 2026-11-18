package com.maba.upscalertest;

/** Controller surface used by the app; implemented by the native C header and the Java port. */
public interface DynController {
    void setMode(int mode);
    void setTargetFps(float fps);
    /** Restrict Dynamic mode to a render-scale range (0.35 .. 1.00; 1.00 is native resolution). */
    void setScaleRange(float minScale, float maxScale);
    void updateDynamic(float frameMs);
    int rung();
}
