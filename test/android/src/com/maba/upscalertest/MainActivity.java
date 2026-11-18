package com.maba.upscalertest;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.opengl.EGL14;
import android.opengl.GLES30;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.Arrays;
import java.nio.ByteBuffer;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * MABA Upscaler test bed - "MABA Core" 3D scene.
 *
 * Renders a real 3D scene (striped torus knot, thin emissive spokes, grid floor, orbiting
 * camera) at a reduced resolution and upscales it with MABA. Tap cycles modes; long-press
 * opens settings (sharpness, target fps). Modes: Dynamic, Ultra Quality, Quality, Balanced,
 * Performance, Bilinear, Native, and MABA-Upscaler 2 (Temporal) dynamic.
 *
 * Dynamic mode is driven by GPU timer queries when available (EXT_disjoint_timer_query), so it
 * sees headroom under vsync. The thermal API lowers the target to 30 fps when the device
 * throttles. At start-up every mode is benchmarked off-screen; results go to logcat tag MABA.
 *
 * Intent extras:
 *   mode (0-7), anim (0/1), loadmul (float)
 *   dump=1 pattern=N rung=R quality=0/1  -> render a reference pattern, write dump.ppm, exit
 */
public class MainActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MABA";

    private static final int DYNAMIC = 0, BILINEAR = 5, NATIVE = 6, TEMPORAL = 7, MODE_COUNT = 8;
    private static final String[] MODE_NAMES = {
        "Dynamic", "Ultra Quality", "Quality", "Balanced", "Performance",
        "Bilinear 0.59 (no MABA)", "Native resolution", "MABA-Upscaler 2 (Temporal)"
    };
    // Native resolution is the top rung of the ladder (scale 1.00), not a special value.
    private static final int[] MODE_RUNG = {10, 28, 18, 10, 0, 9, MabaController.RUNG_CEIL, 10};
    /** "No rung yet" for change detection. Not -1: every rung from -15 to 51 is a real position. */
    private static final int NO_RUNG = Integer.MIN_VALUE;

    private static final double CALIBRATION_MS = 13.0;

    private GLSurfaceView glView;
    private Object thermalListener;   // PowerManager.OnThermalStatusChangedListener on API 29+
    private TextView label;
    private LinearLayout settings;
    private SeekBar sharpBar;
    private Button targetBtn;
    private volatile int mode = DYNAMIC;
    private volatile boolean modeChanged = true;
    private boolean anim = true;
    private float loadMul = 1f;
    // Written on the UI thread, read on the GL thread.
    private volatile float sharpness = 0.5f;
    private volatile int userTargetFps = 60;
    private volatile int thermalStatus = 0;
    private volatile boolean targetChanged = true;
    // VSync off (the default) = uncapped: frames are presented as soon as they are ready.
    private volatile boolean vsyncWanted = false;
    // The VSync state applied this frame (the user's choice, read once per frame). Frame Gen follows
    // it like every other mode: with VSync off it runs uncapped. A fixed-refresh panel still shows at
    // most one frame per refresh, so above the panel rate the overlay says how many it can display.
    private volatile boolean paced = false;
    // Developer switches for cost breakdowns (am start --ei fgdbg N):
    //   fgdbg 1 = generated frames are plain copies of the last real frame (no warp),
    //   fgdbg 2 = every frame is a real frame (no generated frames).
    private int fgDbg;
    // Developer extras, read once (they were looked up in the Intent bundle on every frame):
    //   qcfast 1 skips the benchmark and runs only the quality phase, tfreeze 1 freezes the scene
    //   for the quality check, tnoshade 1 freezes shading, fgbench 1|2 times real / generated only.
    private boolean devQcFast, devFreeze, devNoShade;
    private int devFgBench;
    private boolean devNoReassert;                  // vsyncreassert 0: set the swap interval once only (diagnostic)
    private float devFgK;                      // fgk: force the Frame Gen resolution scale (0 = automatic)
    private float devQfgOff = 0.5f;             // qfgoff: how far ahead the quality check predicts (0.333 / 0.667 = 3x)
    private int devQfgRung = 10;               // qfgrung: the render rung the Frame Gen quality check runs at
    private volatile boolean qcRequested;       // the settings button: run the image-quality check now
    private String benchBaseText = "";          // the benchmark table, without the quality lines
    // The swap interval last requested (-1 = none yet), and when it is asserted again: see onDrawFrame.
    private int appliedVsync = -1;
    private int swapNextFrame, swapGap = 2;
    private static final int SWAP_REASSERT_MAX = 240;
    private Button vsyncBtn;
    // Frame-rate targets for Dynamic mode: from a 30 fps battery budget to a 240 Hz panel.
    private static final int[] TARGETS = {30, 45, 60, 90, 120, 144, 165, 240};
    // The render-scale range Dynamic mode may use, cycled by a settings button. The default is the
    // whole ladder (0.35 .. native): no hardware class is capped. Extras smin / smax override it.
    private static final String[] RANGE_NAMES = {
        "0.35 - 1.00 (whole ladder)", "0.50 - 0.77 (classic mobile)", "0.67 - 1.00 (quality floor)",
        "0.35 - 0.77 (performance)"};
    private static final float[][] RANGES = {{0.35f, 1.00f}, {0.50f, 0.77f}, {0.67f, 1.00f}, {0.35f, 0.77f}};
    private volatile int rangeIdx;                  // UI thread writes, GL thread reads
    private volatile boolean rangeChanged = true;   // apply the range to the controller on the GL thread
    private float devScaleMin = -1f, devScaleMax = -1f;
    private Button rangeBtn, thermalBtn;
    // Halve the Dynamic target when the platform reports SEVERE thermal status (never silently).
    private volatile boolean thermalLimit = true;

    // Dump mode (GPU vs CPU-reference comparison).
    private boolean dumpMode;
    private int dumpPattern, dumpRung, dumpQuality;

    private int progScene, progBg, progBlit, progFast, progQuality, progTemporal, progPattern;
    private final Scene3D scene = new Scene3D();
    private final GpuTimer gpuTimer = new GpuTimer();
    // The real C controller via JNI when the native lib is present; the parity-tested Java
    // port otherwise.
    private final DynController dyn = MabaNative.available()
        ? new MabaNativeController(MabaController.MODE_DYNAMIC, 60f)
        : new MabaController(MabaController.MODE_DYNAMIC, 60f);
    private final MabaTemporal temporal = new MabaTemporal();

    // Render targets. Scene color is single; depth and resolve ping-pong for temporal.
    private final int[] sceneFbo = new int[2];
    private final int[] depthTex = new int[2];
    private final int[] resolveFbo = new int[2];
    private final int[] resolveTex = new int[2];
    private int sceneTex, outFbo, outTex, outDepthTex;
    private final int[] vao = new int[1];
    private int outW, outH, texW, texH;
    // Frame Gen targets are as large as the screen: at Native resolution a real frame is rendered
    // at the full output size. The upscaler's scene targets are the same size now: the ladder tops
    // out at native, so a render target is never too small for a rung the controller picks.
    private int fgTexW, fgTexH;

    /** True when this frame is rendered at output size and needs no upscale pass. */
    private static boolean isNativeFrame(int m, int rung) {
        return m == NATIVE || (m == DYNAMIC && MabaController.rungNative(rung));
    }
    private int load;
    private String glInfo = "";

    private int frame, slot, lastRung = NO_RUNG;

    // MABA Frame Gen (2x): real frame -> generated frame -> real frame ... see the section below.
    private static final int FG_REAL = 0, FG_GENERATED = 1;
    private static final float CAM_NEAR = 0.1f, CAM_FAR = 40f;   // must match cameraVP
    private volatile boolean fgWanted;          // the "MABA Frame Gen" button
    private volatile int fgFactor = 2;          // 2 = one generated frame per real, 3 = two (optional 3x)
    private int fgFactorApplied = 2;
    private volatile boolean fgActive;          // actually running; decided on the GL thread
    private volatile boolean labelDirty = true;
    private long fgNative;                      // maba_framegen.h state, through JNI
    private boolean fgReady;                    // GL resources and programs available
    private String fgNote = "", fgNoteShown = "";
    private float panelHz = 60f;
    private Button fgBtn;
    private int progSceneFg, progBgFg, progFgWarp, progFgWarpHi;
    private int fgLeanRw, fgLeanRh;

    private int fgShownKind = 0;                      // what the slot just put on screen (0 real, 1 generated)

    // Touch camera: drag to orbit, pinch to zoom. Until the first drag the camera auto-orbits as it always did; the
    // Settings panel can hand it back. The matrices it produces are real camera matrices, so the temporal resolve and
    // Frame Gen (motion vectors from the previous real frame's matrix) see it exactly as they would a game camera.
    private final Object camLock = new Object();
    private volatile boolean camUser;                 // the touch camera is in control
    private boolean camInitPending;                   // first drag seen: take over from the current auto pose (under camLock)
    private float camYaw, camPitch = 0.3f, camDist = 4.6f;
    private float camDYaw, camDPitch, camDZoom = 1f;  // touch input accumulated since the last real frame (under camLock)
    private float touchX, touchY, touchSpan;
    private static final float CAM_TARGET_Y = 0.05f;  // what the camera looks at (also in cameraVP)

    // Input-latency probe (developer: --ei lat 1; driven by test/android/latency_u3.ps1). A tap counts as "sampled" at
    // the start of the first real-slot frame after it (where a game would read its input). When each presented frame
    // reached the glass comes from EGL_ANDROID_get_frame_timestamps. All clocks are CLOCK_MONOTONIC.
    private boolean latMode, latOk;

    private volatile long latTouchNs;
    private static final int LAT_RING = 512, LAT_MAX = 16;
    private final long[] latFrameId = new long[LAT_RING];
    private final int[] latShown = new int[LAT_RING];
    private int latCount;                              // swaps recorded so far (index of the next one)
    private final int[] latSIdx = new int[LAT_MAX];    // pending samples: swap index at the sample, touch time, frame start
    private final long[] latSTouch = new long[LAT_MAX], latSStart = new long[LAT_MAX];
    private int latPending;
    private final long[] latTsA = new long[4], latTsB = new long[4];
    private long fgGov;                               // native Frame Gen governor
    private boolean fgGovEnabled = true, fgGovOn = true;
    private long govLastRealNanos;
    private final float[] fgGovInfo = new float[3];
    private volatile boolean leanHave;   // a real frame exists to extrapolate from (lean Frame Gen); cleared on any change of size
    private boolean temporalVelocity = true;
    private final int[] tFbo = new int[2];       // scene + motion vectors + depth, for the Temporal tier
    private int tVel;
    // Temporal SR: accumulates at OUTPUT resolution (history srTex), then a present pass sharpens.
    // --ei tsr 0 keeps the older render-resolution Temporal path for comparison.
    private int progTsr, progTsrPresent;
    private final int[] srTex = new int[2], srFbo = new int[2];
    private int srShown;                         // the image to show (second render target of the resolve)
    private boolean tsrEnabled = true;
    /** GLSL ES has no implicit int-to-float conversion: a developer extra like "7" must reach the shader as "7.0". */
    private static String fl(String v) { return Float.toString(Float.parseFloat(v)); }
    private String modeName(int m) { return m == TEMPORAL ? "MABA Upscaler 3" : MODE_NAMES[m]; }
    private float tsrSharpAbs = -1f;             // developer: absolute present sharpen strength

    private boolean tsrActive() {
        return tsrEnabled && temporalVelocity && progTsr != 0 && progTsrPresent != 0 && srFbo[0] != 0;
    }
    private float tPrevTime = -1f;
    private final int[] fgColor = new int[2], fgVel = new int[2], fgDepth = new int[2], fgFbo = new int[2];
    private int genTex, genFbo;
    private int fgWriteSlot, fgCurSlot, fgCurRw, fgCurRh, fgPrevRw, fgPrevRh;
    private boolean fgHavePrev, lastFboOk = true;
    private float fgPrevTime, benchFgTime;
    private long fgLastRealNanos;
    private int fgProbeCountdown = 60, fgLastRung = NO_RUNG;
    private boolean fgProbeGenPending, fgStatsValid;
    private float fgProbeRealMs, fgProbeGenMs;
    private final float[] fgStats = new float[3];     // real, generated, shown fps (last 1 s window)
    private float fgRealBiasMs, fgGenBiasMs;          // latency-vs-throughput calibration from the benchmark
    private String fgBenchText = "benchmark pending...";

    private float probeMs;
    private int probeCountdown = 60;
    private final Mat4 prevVP = Mat4.identity();   // previous frame's UNJITTERED view-projection
    private boolean havePrevVP;
    private boolean benchDone = true;       // MABA Upscaler 3 has no start-up benchmark of the old modes
    // ---- MABA Upscaler 3: one mode, MABA temporal super-resolution with presets ----
    private static final boolean u3Only = true;
    // Presets: render scale (Balance Lite sits between Performance and Balanced).
    private static final String[] PRESET_NAMES = {"Performance", "Balanced", "Balance Lite", "Quality", "Ultra Quality"};
    private static final float[] PRESET_SCALE = {0.50f, 0.59f, 0.55f, 0.67f, 0.77f};
    private int progTsrLite;
    private volatile int presetIdx = 1;
    private volatile boolean resetNow;           // the "Reset history" button; handled on the GL thread
    private int presetRung() { return MabaController.scaleToRung(PRESET_SCALE[presetIdx]); }
    private volatile boolean govReset = true;
    private void pollReset() {
        if (resetNow) { resetNow = false; temporal.reset(); havePrevVP = false; leanHave = false; govReset = true; }
    }
    /** Restarts the Frame Gen governor's measurements (new preset, Frame Gen toggled, scene change). */
    private void restartGovernor() {
        if (!govReset) return;
        govReset = false;
        if (fgGov != 0) MabaNative.govDestroy(fgGov);
        fgGov = fgNative != 0 ? MabaNative.govCreate(panelHz) : 0;
        fgGovOn = false;                                   // the governor starts by measuring the plain rate
        govLastRealNanos = 0;
    }

    private void postLabel(int rung) {
        float scale = MabaController.rungScale(rung);
        int rw = Math.max(2, Math.round(outW * scale)), rh = Math.max(2, Math.round(outH * scale));
        StringBuilder sb = new StringBuilder();
        sb.append(String.format(Locale.US, "MABA Upscaler 3  |  %s  |  render %dx%d -> %dx%d (%.1fx)  |  VSync %s",
            fgStatsValid ? String.format(Locale.US, "%.1f fps (%.1f ms)", fgStats[2], fgStats[2] > 0 ? 1000f / fgStats[2] : 0f) : "-- fps",
            rw, rh, outW, outH, 1f / PRESET_SCALE[presetIdx], vsyncWanted ? "on" : "OFF"));
        sb.append("\nPreset: ").append(PRESET_NAMES[presetIdx]);
        sb.append("\nsharpening ").append(String.format(Locale.US, "%.2f", sharpness)).append("  |  Settings: top right");
        sb.append("\nDrag to orbit the camera, pinch to zoom");
        if (fgActive) {
            String gov = "";
            if (fgGovEnabled && fgGov != 0) {
                gov = fgGovOn ? "  |  auto: on" : "  |  auto: paused (it would not show more frames than leaving it off)";
                if (fgGovOn && fgGovInfo[1] > 0 && fgGovInfo[2] > 0) gov += String.format(Locale.US, " (%.0f fps vs %.0f without)",
                    Math.min(2000f / fgGovInfo[1], panelHz), Math.min(1000f / fgGovInfo[2], panelHz));
            }
            sb.append(String.format(Locale.US, "\nFrame Gen %dx %s: REAL %.1f + GENERATED %.1f = OUTPUT %.1f fps%s",
                fgFactorApplied, "extrapolated", fgStats[0], fgStats[1], fgStats[2], gov));
        }
        if (fgStatsValid) Log.i(TAG, String.format(Locale.US, "STATS fg=%s real=%.1f gen=%.1f out=%.1f gov=%s", fgActive ? (fgFactorApplied + "x extrap") : "off", fgStats[0], fgStats[1], fgStats[2], fgGovOn ? "on" : "paused"));
        if (qcRunning) sb.append("\nchecking quality... ").append(qcStep * 100 / Math.max(1, qcSteps())).append('%');
        else if (!upQualityText.isEmpty()) sb.append('\n').append(upQualityText);
        sb.append('\n').append(glInfo);
        final String text = sb.toString();
        runOnUiThread(new Runnable() { @Override public void run() { label.setText(text); } });
    }
    private String benchText = "benchmark pending...";
    private long startNanos, lastNanos;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getPreferences(MODE_PRIVATE);
        mode = TEMPORAL;
        anim = getIntent().getIntExtra("anim", 1) != 0;
        loadMul = getIntent().getFloatExtra("loadmul", 1f);
        sharpness = getIntent().hasExtra("sharp") ? Float.parseFloat(getIntent().getStringExtra("sharp"))
            : prefs.getFloat("sharpness", 0.5f);
        userTargetFps = getIntent().hasExtra("target") ? getIntent().getIntExtra("target", 60)
            : prefs.getInt("targetFps", 60);
        rangeIdx = Math.max(0, Math.min(RANGES.length - 1, prefs.getInt("scaleRange", 0)));
        thermalLimit = prefs.getBoolean("thermalLimit", true);
        if (getIntent().hasExtra("smin")) devScaleMin = Float.parseFloat(getIntent().getStringExtra("smin"));
        if (getIntent().hasExtra("smax")) devScaleMax = Float.parseFloat(getIntent().getStringExtra("smax"));
        vsyncWanted = getIntent().hasExtra("vsync") ? getIntent().getIntExtra("vsync", 0) == 1
            : prefs.getBoolean("vsync", false);
        dumpMode = getIntent().getIntExtra("dump", 0) == 1;
        dumpPattern = getIntent().getIntExtra("pattern", 0);
        dumpRung = getIntent().getIntExtra("rung", 10);
        dumpQuality = getIntent().getIntExtra("quality", 0);
        fgWanted = getIntent().getIntExtra("fg", 0) == 1 || getIntent().getIntExtra("fg", 0) == 3;
        fgFactor = getIntent().getIntExtra("fg", 0) == 3 ? 3 : 2;      // --ei fg 3 = 3x
        fgDbg = getIntent().getIntExtra("fgdbg", 0);
        devQcFast = getIntent().getIntExtra("qcfast", 0) == 1;
        devFreeze = getIntent().getIntExtra("tfreeze", 0) == 1;
        devNoShade = getIntent().getIntExtra("tnoshade", 0) == 1;
        devFgBench = getIntent().getIntExtra("fgbench", 0);
        if (getIntent().hasExtra("qfgoff")) devQfgOff = Float.parseFloat(getIntent().getStringExtra("qfgoff"));
        devNoReassert = getIntent().getIntExtra("vsyncreassert", 1) == 0;
        if (getIntent().hasExtra("fgk")) devFgK = Float.parseFloat(getIntent().getStringExtra("fgk"));
        devQfgRung = Math.max(MabaController.RUNG_FLOOR, Math.min(MabaController.RUNG_CEIL,
            getIntent().getIntExtra("qfgrung", 10)));
        if (getIntent().getIntExtra("qsweep", 0) == 1) qcRungs = QC_SWEEP_RUNGS;
        QC_TEMPORAL_FRAMES = Math.max(2, getIntent().getIntExtra("qtf", 12));
        // Developer overrides for the Temporal tier, used by the quality harness.
        if (getIntent().hasExtra("thw")) temporal.historyWeight = Float.parseFloat(getIntent().getStringExtra("thw"));
        if (getIntent().hasExtra("tgamma")) temporal.clipGamma = Float.parseFloat(getIntent().getStringExtra("tgamma"));
        // In the motion-vector mode the tolerance is relative (view-space); camera-only mode uses window depth.
        if (getIntent().getIntExtra("tvel", 1) == 1) temporal.depthTolerance = 0.05f;
        if (getIntent().hasExtra("tdepth")) temporal.depthTolerance = Float.parseFloat(getIntent().getStringExtra("tdepth"));
        fgNative = MabaNative.available() ? MabaNative.fgCreate() : 0;
        panelHz = getWindowManager().getDefaultDisplay().getRefreshRate();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        GLSurfaceView view = new GLSurfaceView(this);
        glView = view;
        view.setEGLContextClientVersion(3);
        // Developer: render at an output size larger than the screen (the compositor scales it down),
        // to measure how every pass scales with resolution: --ei outw 2312 --ei outh 1080
        if (getIntent().hasExtra("outw") && getIntent().hasExtra("outh")) {
            view.getHolder().setFixedSize(getIntent().getIntExtra("outw", 0), getIntent().getIntExtra("outh", 0));
        }
        latMode = getIntent().getIntExtra("lat", 0) == 1;
        view.setOnTouchListener(new View.OnTouchListener() {
            @Override public boolean onTouch(View v, MotionEvent ev) {
                handleCameraTouch(ev);
                if (latMode && ev.getActionMasked() == MotionEvent.ACTION_DOWN) latTouchNs = ev.getEventTime() * 1000000L;
                return true;
            }
        });        view.setRenderer(this);
        view.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                /* one mode: MABA Upscaler 3 temporal */
                getPreferences(MODE_PRIVATE).edit().putInt("mode", mode).apply();
            }
        });
        label = new TextView(this);
        label.setTextColor(Color.WHITE);
        label.setTextSize(10f);
        label.setShadowLayer(3f, 1f, 1f, Color.BLACK);
        label.setPadding(16, 8, 16, 8);

        settings = buildPanel();

        FrameLayout root = new FrameLayout(this);
        root.addView(view);
        // The overlay leaves room on the right for the MABA Frame Gen button.
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = 330;
        root.addView(label, lp);
        FrameLayout.LayoutParams sp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        sp.gravity = android.view.Gravity.BOTTOM | android.view.Gravity.CENTER_HORIZONTAL;
        sp.bottomMargin = 24;
        root.addView(settings, sp);

        fgBtn = new Button(this);
        fgBtn.setAllCaps(false);
        fgBtn.setTextSize(12f);
        updateFgButton();
        fgBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                // OFF -> 2x -> 3x -> OFF
                if (!fgWanted) { fgWanted = true; fgFactor = 2; }
                else if (fgFactor == 2) fgFactor = 3;
                else fgWanted = false;
                updateFgButton();
                labelDirty = true;
            }
        });
        FrameLayout.LayoutParams fp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        fp.gravity = android.view.Gravity.TOP | android.view.Gravity.RIGHT;
        fp.topMargin = 12;
        fp.rightMargin = 12;
        root.addView(fgBtn, fp);
        final Button settingsBtn = new Button(this);
        settingsBtn.setAllCaps(false);
        settingsBtn.setTextSize(12f);
        settingsBtn.setText("Settings");
        settingsBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                settings.setVisibility(settings.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE);
            }
        });
        FrameLayout.LayoutParams stp = new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT);
        stp.gravity = android.view.Gravity.TOP | android.view.Gravity.RIGHT;
        stp.topMargin = 112;
        stp.rightMargin = 12;
        root.addView(settingsBtn, stp);        setContentView(root);
        view.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);

        if (Build.VERSION.SDK_INT >= 29) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            PowerManager.OnThermalStatusChangedListener l = new PowerManager.OnThermalStatusChangedListener() {
                @Override public void onThermalStatusChanged(int status) {
                    thermalStatus = status;
                    applyTargetFps();
                    Log.i(TAG, "THERMAL status=" + status + " target=" + effectiveTargetFps() + "fps");
                }
            };
            pm.addThermalStatusListener(getMainExecutor(), l);
            thermalListener = l;
        }
    }

    // GLSurfaceView must be told about the activity lifecycle, or its render thread keeps
    // drawing (and draining the battery) while the app is in the background.
    @Override
    protected void onPause() {
        super.onPause();
        if (glView != null) glView.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (glView != null) glView.onResume();
    }

    @Override
    protected void onDestroy() {
        // onPause (always before this) has stopped the render thread, so freeing native state is safe.
        if (fgNative != 0) { MabaNative.fgDestroy(fgNative); fgNative = 0; }
        if (dyn instanceof MabaNativeController) ((MabaNativeController) dyn).release();
        if (Build.VERSION.SDK_INT >= 29 && thermalListener != null) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            pm.removeThermalStatusListener((PowerManager.OnThermalStatusChangedListener) thermalListener);
            thermalListener = null;
        }
        super.onDestroy();
    }

    /** The user's target, capped at 30 fps when the platform reports SEVERE (3) thermal status and
     *  the thermal limit is on. A merely warm device (MODERATE) is not a reason to cap anything:
     *  the controller already follows the measured frame time. */
    private int effectiveTargetFps() {
        return (thermalLimit && thermalStatus >= 3) ? Math.min(userTargetFps, 30) : userTargetFps;
    }

    /** GL thread: hands the selected render-scale range to the Dynamic controller. */
    private void applyScaleRange() {
        float lo, hi;
        if (devScaleMin >= 0f || devScaleMax >= 0f) {
            lo = devScaleMin >= 0f ? devScaleMin : RANGES[0][0];
            hi = devScaleMax >= 0f ? devScaleMax : RANGES[0][1];
        } else {
            lo = RANGES[rangeIdx][0];
            hi = RANGES[rangeIdx][1];
        }
        dyn.setScaleRange(lo, hi);
        Log.i(TAG, String.format(Locale.US, "Dynamic range %.2f .. %.2f", lo, hi));
    }

    /** What the Dynamic controller aims for. With Frame Gen it controls the REAL frame rate, which
     *  is half of the output rate. With VSync on the output can never exceed the panel. */
    private float controllerTargetFps() {
        float target = effectiveTargetFps();
        if (paced) target = Math.min(target, panelHz);
        if (fgActive) target = target / (float) fgFactorApplied;
        return target;
    }

    private void updateFgButton() {
        boolean on = fgWanted;
        fgBtn.setText("MABA Frame Gen\n" + (on ? fgFactor + "x" : "OFF"));
        fgBtn.setTextColor(on ? 0xFF111111 : Color.WHITE);
        fgBtn.setBackgroundColor(on ? 0xFFF5A524 : 0xCC303036);
    }

    /** UI / thermal thread: the controller itself is only ever touched on the GL thread. */
    private void applyTargetFps() {
        targetChanged = true;
    }

    private LinearLayout buildPanel() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackgroundColor(0xE0202024);
        panel.setPadding(28, 20, 28, 20);
        panel.setVisibility(View.GONE);
        TextView title = new TextView(this);
        title.setText("MABA Upscaler 3 - settings");
        title.setTextColor(Color.WHITE);
        title.setTextSize(13f);
        panel.addView(title);
        // objects the old settings code still refers to
        sharpBar = new SeekBar(this); targetBtn = new Button(this); rangeBtn = new Button(this); thermalBtn = new Button(this);
        TextView sl = new TextView(this);
        sl.setTextColor(0xFFCCCCCC); sl.setTextSize(11f); sl.setText("Sharpening");
        panel.addView(sl);
        SeekBar sb = new SeekBar(this);
        sb.setMax(100); sb.setProgress(Math.round(sharpness * 100));
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) { sharpness = p / 100f; labelDirty = true; }
            @Override public void onStartTrackingTouch(SeekBar s) {}
            @Override public void onStopTrackingTouch(SeekBar s) {}
        });
        panel.addView(sb, new LinearLayout.LayoutParams(420, LinearLayout.LayoutParams.WRAP_CONTENT));
        final Button ratio = new Button(this);
        ratio.setTextSize(11f);
        ratio.setText("Preset: " + PRESET_NAMES[presetIdx]);
        ratio.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            presetIdx = (presetIdx + 1) % PRESET_NAMES.length;
            ratio.setText("Preset: " + PRESET_NAMES[presetIdx]);
            leanHave = false; resetNow = true; labelDirty = true; } });
        panel.addView(ratio);
        final Button camBtn = new Button(this);
        camBtn.setTextSize(11f);
        camBtn.setText("Camera: back to auto orbit");
        camBtn.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            camUser = false;                      // the next drag takes over again from wherever the auto camera is
            resetNow = true; labelDirty = true; } });
        panel.addView(camBtn);
        final Button fgAuto = new Button(this);
        fgAuto.setTextSize(11f);
        fgAuto.setText(fgGovEnabled ? "Frame Gen auto-pause: ON (never slower than off)" : "Frame Gen auto-pause: off");
        fgAuto.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            fgGovEnabled = !fgGovEnabled;
            fgAuto.setText(fgGovEnabled ? "Frame Gen auto-pause: ON (never slower than off)" : "Frame Gen auto-pause: off");
            leanHave = false; resetNow = true; labelDirty = true; } });
        panel.addView(fgAuto);
        vsyncBtn = new Button(this);
        vsyncBtn.setTextSize(11f); vsyncBtn.setText("VSync: toggle");
        vsyncBtn.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { vsyncWanted = !vsyncWanted; labelDirty = true; } });
        panel.addView(vsyncBtn);
        Button quality = new Button(this);
        quality.setTextSize(11f); quality.setText("Run image-quality check");
        quality.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { qcRequested = true; } });
        panel.addView(quality);
        Button reset = new Button(this);
        reset.setTextSize(11f); reset.setText("Reset history");
        reset.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { resetNow = true; } });
        panel.addView(reset);
        Button close = new Button(this);
        close.setTextSize(11f); close.setText("Close");
        close.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { settings.setVisibility(View.GONE); } });
        panel.addView(close);
        return panel;
    }

    private LinearLayout buildSettingsPanel() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackgroundColor(0xE0202024);
        panel.setPadding(28, 20, 28, 20);
        panel.setVisibility(View.GONE);

        TextView title = new TextView(this);
        title.setText("MABA settings");
        title.setTextColor(Color.WHITE);
        title.setTextSize(13f);
        panel.addView(title);

        TextView sharpLabel = new TextView(this);
        sharpLabel.setTextColor(0xFFCCCCCC);
        sharpLabel.setTextSize(11f);
        sharpLabel.setText("Sharpness");
        panel.addView(sharpLabel);

        sharpBar = new SeekBar(this);
        sharpBar.setMax(100);
        sharpBar.setProgress(Math.round(sharpness * 100));
        sharpBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean user) {
                sharpness = p / 100f;
                getPreferences(MODE_PRIVATE).edit().putFloat("sharpness", sharpness).apply();
            }
            @Override public void onStartTrackingTouch(SeekBar s) {}
            @Override public void onStopTrackingTouch(SeekBar s) {}
        });
        panel.addView(sharpBar, new LinearLayout.LayoutParams(420, LinearLayout.LayoutParams.WRAP_CONTENT));

        targetBtn = new Button(this);
        targetBtn.setTextSize(11f);
        targetBtn.setText("Target: " + userTargetFps + " fps");
        targetBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                int next = TARGETS[0];
                for (int i = 0; i < TARGETS.length; i++) {
                    if (TARGETS[i] == userTargetFps) { next = TARGETS[(i + 1) % TARGETS.length]; break; }
                }
                userTargetFps = next;
                targetBtn.setText("Target: " + userTargetFps + " fps");
                getPreferences(MODE_PRIVATE).edit().putInt("targetFps", userTargetFps).apply();
                applyTargetFps();
            }
        });
        panel.addView(targetBtn);

        vsyncBtn = new Button(this);
        vsyncBtn.setTextSize(11f);
        vsyncBtn.setText(vsyncWanted ? "VSync: ON (capped to the panel)" : "VSync: OFF (uncapped)");
        vsyncBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                vsyncWanted = !vsyncWanted;
                vsyncBtn.setText(vsyncWanted ? "VSync: ON (capped to the panel)" : "VSync: OFF (uncapped)");
                getPreferences(MODE_PRIVATE).edit().putBoolean("vsync", vsyncWanted).apply();
                applyTargetFps();
                labelDirty = true;
            }
        });
        panel.addView(vsyncBtn);

        rangeBtn = new Button(this);
        rangeBtn.setTextSize(11f);
        rangeBtn.setText("Dynamic range: " + RANGE_NAMES[rangeIdx]);
        rangeBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                rangeIdx = (rangeIdx + 1) % RANGES.length;
                rangeBtn.setText("Dynamic range: " + RANGE_NAMES[rangeIdx]);
                getPreferences(MODE_PRIVATE).edit().putInt("scaleRange", rangeIdx).apply();
                rangeChanged = true;
                labelDirty = true;
            }
        });
        panel.addView(rangeBtn);

        thermalBtn = new Button(this);
        thermalBtn.setTextSize(11f);
        thermalBtn.setText(thermalLimit ? "Thermal limit: ON (halves the target at SEVERE)" : "Thermal limit: OFF");
        thermalBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                thermalLimit = !thermalLimit;
                thermalBtn.setText(thermalLimit ? "Thermal limit: ON (halves the target at SEVERE)" : "Thermal limit: OFF");
                getPreferences(MODE_PRIVATE).edit().putBoolean("thermalLimit", thermalLimit).apply();
                applyTargetFps();
            }
        });
        panel.addView(thermalBtn);

        // The image-quality check renders reference frames and reads pixels back, which drops the
        // frame rate for a few seconds, so it only runs when asked for (or with --ei qcstart 1).
        Button qcBtn = new Button(this);
        qcBtn.setTextSize(11f);
        qcBtn.setText("Run image-quality check (a few seconds of low fps)");
        qcBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                qcRequested = true;
                settings.setVisibility(View.GONE);
            }
        });
        panel.addView(qcBtn);

        Button close = new Button(this);
        close.setTextSize(11f);
        close.setText("Close");
        close.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { settings.setVisibility(View.GONE); }
        });
        panel.addView(close);
        return panel;
    }

    // ---------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------

    private String asset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toString("UTF-8");
        } catch (Exception e) {
            throw new RuntimeException("missing asset " + name, e);
        }
    }

    private int shader(int type, String src, String name) {
        int s = GLES30.glCreateShader(type);
        GLES30.glShaderSource(s, src);
        GLES30.glCompileShader(s);
        int[] ok = new int[1];
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.e(TAG, "compile failed: " + name + "\n" + GLES30.glGetShaderInfoLog(s));
            GLES30.glDeleteShader(s);
            return 0;
        }
        return s;
    }

    // Uniform locations by program and name: the per-frame passes would otherwise call into the
    // driver with a freshly marshalled string for every uniform, every frame. Cleared with every
    // new GL context (program ids are only unique within one).
    private final android.util.SparseArray<java.util.HashMap<String, Integer>> uniformLocs =
        new android.util.SparseArray<>();

    private int uloc(int prog, String name) {
        java.util.HashMap<String, Integer> byName = uniformLocs.get(prog);
        if (byName == null) {
            byName = new java.util.HashMap<>();
            uniformLocs.put(prog, byName);
        }
        Integer loc = byName.get(name);
        if (loc == null) {
            loc = GLES30.glGetUniformLocation(prog, name);
            byName.put(name, loc);
        }
        return loc;
    }

    private int program(String header, String vert, String frag, String name) {
        int vs = shader(GLES30.GL_VERTEX_SHADER, header + vert, name + ".vert");
        int fs = shader(GLES30.GL_FRAGMENT_SHADER, header + frag, name + ".frag");
        if (vs == 0 || fs == 0) {
            if (vs != 0) GLES30.glDeleteShader(vs);
            if (fs != 0) GLES30.glDeleteShader(fs);
            return 0;
        }
        int p = GLES30.glCreateProgram();
        GLES30.glAttachShader(p, vs);
        GLES30.glAttachShader(p, fs);
        GLES30.glLinkProgram(p);
        int[] ok = new int[1];
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0);
        // The program keeps what it needs; the shader objects can go either way.
        GLES30.glDeleteShader(vs);
        GLES30.glDeleteShader(fs);
        if (ok[0] == 0) {
            Log.e(TAG, "link failed: " + name + "\n" + GLES30.glGetProgramInfoLog(p));
            GLES30.glDeleteProgram(p);
            return 0;
        }
        return p;
    }

    @Override
    public void onSurfaceCreated(GL10 unused, EGLConfig config) {
        String version = GLES30.glGetString(GLES30.GL_VERSION);
        boolean es31 = version != null && (version.contains("ES 3.1") || version.contains("ES 3.2"));
        glInfo = GLES30.glGetString(GLES30.GL_RENDERER) + " | " + version;
        Log.i(TAG, "GL: " + glInfo);

        String vert = asset("maba_upscaler.vert.glsl");
        String maba = asset("maba_upscaler.frag.glsl");
        String h30 = "#version 300 es\n";
        String h31 = "#version 310 es\n";

        // A new EGL context invalidates every GL object from the old one.
        uniformLocs.clear();
        progFast = progQuality = progTemporal = 0;
        sceneTex = 0;
        Arrays.fill(tFbo, 0);
        tVel = 0;
        Arrays.fill(srFbo, 0); Arrays.fill(srTex, 0);
        srShown = 0;
        ssFbo = ssColor = ssDepth = 0;
        rangeChanged = true;      // a new context starts from a fresh controller state
        Arrays.fill(fgColor, 0); Arrays.fill(fgVel, 0); Arrays.fill(fgDepth, 0); Arrays.fill(fgFbo, 0);
        genTex = genFbo = 0;
        fgReady = false;
        fgActive = false;
        fgHavePrev = false;
        if (fgNative != 0) MabaNative.fgSetEnabled(fgNative, 0);
        fgStatsValid = false;
        fgLastRealNanos = 0;
        fgProbeRealMs = fgProbeGenMs = 0f;
        labelDirty = true;
        appliedVsync = -1;
        swapNextFrame = 0;
        swapGap = 2;

        progScene = program(h30, asset("scene3d.vert.glsl"), asset("scene3d.frag.glsl"), "scene3d");
        progBg = program(h30, vert, asset("bg.frag.glsl"), "bg");
        progBlit = program(h30, vert, asset("blit.frag.glsl"), "blit");
        progPattern = program(h30, vert, asset("pattern.frag.glsl"), "pattern");
        if (es31) {
            progFast = program(h31 + "#define MABA_GATHER 1\n", vert, maba, "maba-fast");
            progQuality = program(h31 + "#define MABA_GATHER 1\n#define MABA_QUALITY 1\n#define MABA_HIGHP 1\n"
                + (getIntent().hasExtra("qlo") ? "#define MABA_EDGE_LO (" + getIntent().getStringExtra("qlo") + " / 255.0)\n" : "")
                + (getIntent().hasExtra("qhi") ? "#define MABA_EDGE_HI (" + getIntent().getStringExtra("qhi") + " / 255.0)\n" : "")
                + (getIntent().hasExtra("qgain") ? "#define MABA_QUALITY_GAIN " + getIntent().getStringExtra("qgain") + "\n" : ""),
                vert, maba, "maba-quality");
        }
        if (progFast == 0) progFast = program(h30 + "#define MABA_GATHER 0\n", vert, maba, "maba-es30");
        if (progQuality == 0) progQuality = progFast;
        // The Temporal tier reprojects with the per-pixel motion vectors the scene writes (camera and
        // objects). A Catmull-Rom history resample (+0.1 dB for ~0.5 ms) is available with tsharp=1.
        progTemporal = program(h30
            + (getIntent().getIntExtra("tvel", 1) == 1 ? "#define MABA_TEMPORAL_VELOCITY 1\n" : "")
            + (getIntent().getIntExtra("tsharp", 0) == 1 ? "#define MABA_TEMPORAL_SHARP 1\n" : "")
            + (getIntent().hasExtra("tmk") ? "#define MABA_TEMPORAL_MOTION_K " + getIntent().getStringExtra("tmk") + "\n" : ""),
            vert, asset("maba_temporal.frag.glsl"), "maba-temporal");
        if (progTemporal == 0) Log.e(TAG, "temporal unavailable; mode 7 falls back to Dynamic");
        // Temporal SR: resolve at output resolution + present (sharpen). Developer extras: tsrr /
        // tsrrw (narrow / wide kernel), tsrprior (wide-estimate weight), tsrwmax (weight cap), tsrk
        // (motion distrust), tsrhist 0 (bilinear history), tsrsharp (absolute present strength).
        tsrEnabled = getIntent().getIntExtra("tsr", 1) == 1;
        if (getIntent().hasExtra("tsrsharp")) tsrSharpAbs = Float.parseFloat(getIntent().getStringExtra("tsrsharp"));
        String tsrSrc = asset("maba_temporal_sr.frag.glsl");
        progTsr = program(h30
            + (getIntent().hasExtra("tsrr") ? "#define MABA_TSR_R " + fl(getIntent().getStringExtra("tsrr")) + "\n" : "")
            + (getIntent().getIntExtra("tsrhist", 1) == 0 ? "#define MABA_TSR_SHARP 0\n" : "")
            + (getIntent().hasExtra("tsrk") ? "#define MABA_TSR_MOTION_K " + fl(getIntent().getStringExtra("tsrk")) + "\n" : "")
            + (getIntent().hasExtra("tsrwmax") ? "#define MABA_TSR_WMAX " + fl(getIntent().getStringExtra("tsrwmax")) + "\n" : "")
            + "#define MABA_TSR_HIGHP " + getIntent().getIntExtra("tsrhp", 0) + "\n"   // half-precision colour maths: measured identical quality, faster
            + (getIntent().hasExtra("tsrtaps") ? "#define MABA_TSR_TAPS " + getIntent().getIntExtra("tsrtaps", 3) + "\n" : "")
            + (getIntent().hasExtra("tsrrw") ? "#define MABA_TSR_RW " + fl(getIntent().getStringExtra("tsrrw")) + "\n" : "")
            + (getIntent().hasExtra("tsrprior") ? "#define MABA_TSR_PRIOR " + fl(getIntent().getStringExtra("tsrprior")) + "\n" : ""),
            vert, tsrSrc, "maba-tsr");
        progTsrPresent = program(h30 + "#define MABA_TSR_PRESENT 1\n", vert, tsrSrc, "maba-tsr-present");
        progTsrLite = program(h30 + "#define MABA_TSR_HIGHP 0\n", vert, tsrSrc, "maba-tsr-lite");   // Balance Lite: half-precision colour maths
        if (getIntent().hasExtra("preset")) presetIdx = Math.max(0, Math.min(PRESET_NAMES.length - 1, getIntent().getIntExtra("preset", 1)));
        if (getIntent().hasExtra("pscale")) PRESET_SCALE[presetIdx] = Math.max(0.35f, Math.min(1.0f, Float.parseFloat(getIntent().getStringExtra("pscale"))));   // developer: render scale override (1.0 = native)
        if (getIntent().getIntExtra("qcauto", 0) == 1) qcRequested = true;
        if (progTsr == 0 || progTsrPresent == 0) Log.w(TAG, "Temporal SR unavailable, using the render-resolution path");

        // MABA Frame Gen: scene and sky variants that also write motion vectors, and the three
        // warp passes.
        String hv = h30 + "#define MABA_VELOCITY 1\n";
        String fgSrc = asset("maba_framegen.frag.glsl");
        progSceneFg = program(hv, asset("scene3d.vert.glsl"), asset("scene3d.frag.glsl"), "scene3d-fg");
        progBgFg = program(hv, vert, asset("bg.frag.glsl"), "bg-fg");
        // Developer extras to take the warp apart on the device: fgprobe N (probe taps 0-8),
        // fgnoedge 1 (read the probe, never take the edge path).
        String warpDefs = (getIntent().hasExtra("fgprobe")
                ? "#define MABA_FG_PROBE_TAPS " + getIntent().getIntExtra("fgprobe", 8) + "\n" : "")
            + (getIntent().hasExtra("fgmask")
                ? "#define MABA_FG_SCALE_MASK " + getIntent().getIntExtra("fgmask", 1) + "\n" : "")
            + (getIntent().getIntExtra("fgnoedge", 0) == 1 ? "#define MABA_FG_NOEDGE 1\n" : "");
        progFgWarp = program(h30 + warpDefs, vert, fgSrc, "fg-warp");
        progFgWarpHi = program(h30 + warpDefs + "#define MABA_FG_COLOR_SEPARATE 1\n", vert, fgSrc, "fg-warp-hi");
        fgGovEnabled = getIntent().getIntExtra("fggov", 1) == 1;


        GLES30.glGenVertexArrays(1, vao, 0);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glDisable(GLES30.GL_BLEND);
        scene.init();
        gpuTimer.init();
        Log.i(TAG, "GPU timer: " + (gpuTimer.supported ? "EXT_disjoint_timer_query" : "unsupported"));
        // A new context also follows every resume from the background: keep the animation
        // clock running (no camera jump), and restart frame timing so neither the fps counter
        // nor the Dynamic controller sees the paused time as one giant frame.
        if (startNanos == 0) startNanos = System.nanoTime();
        lastNanos = 0;
        targetChanged = true;
    }

    private int colorTarget(int w, int h) {
        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[0]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, w, h, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        return tex[0];
    }

    private int depthTarget(int w, int h) {
        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[0]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, 0x81A6 /* DEPTH_COMPONENT24 */, w, h, 0,
            GLES30.GL_DEPTH_COMPONENT, GLES30.GL_UNSIGNED_INT, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        return tex[0];
    }

    private int fboWith(int colorTex, int depthTex) {
        int[] fbo = new int[1];
        GLES30.glGenFramebuffers(1, fbo, 0);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, colorTex, 0);
        if (depthTex != 0) {
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_DEPTH_ATTACHMENT,
                GLES30.GL_TEXTURE_2D, depthTex, 0);
        }
        int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
        lastFboOk = status == GLES30.GL_FRAMEBUFFER_COMPLETE;
        if (!lastFboOk) Log.e(TAG, "FBO incomplete: " + status);
        return fbo[0];
    }

    /** Half-float data texture (NEAREST, clamped) for the motion vectors. */
    private int halfFloatTarget(int w, int h, int internalFormat, int format) {
        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex[0]);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, internalFormat, w, h, 0,
            format, GLES30.GL_HALF_FLOAT, null);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
        return tex[0];
    }

    /** Framebuffer with colour + motion vectors + depth for a Frame Gen real frame. */
    private int fgFboWith(int colorTex, int velTex, int depthTex) {
        int[] fbo = new int[1];
        GLES30.glGenFramebuffers(1, fbo, 0);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, colorTex, 0);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT1,
            GLES30.GL_TEXTURE_2D, velTex, 0);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_DEPTH_ATTACHMENT,
            GLES30.GL_TEXTURE_2D, depthTex, 0);
        GLES30.glDrawBuffers(2, new int[]{GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_COLOR_ATTACHMENT1}, 0);
        int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
        lastFboOk = status == GLES30.GL_FRAMEBUFFER_COMPLETE;
        if (!lastFboOk) Log.e(TAG, "Frame Gen FBO incomplete: " + status);
        return fbo[0];
    }

    private void allocFrameGen() {
        fgReady = false;
        if (progSceneFg == 0 || progBgFg == 0 || progFgWarp == 0) {
            Log.e(TAG, "Frame Gen shaders unavailable");
            return;
        }
        boolean ok = true;
        fgTexW = outW;
        fgTexH = outH;
        for (int i = 0; i < 2; i++) {
            fgColor[i] = colorTarget(fgTexW, fgTexH);
            fgVel[i] = halfFloatTarget(fgTexW, fgTexH, GLES30.GL_RG16F, GLES30.GL_RG);
            fgDepth[i] = depthTarget(fgTexW, fgTexH);
            fgFbo[i] = fgFboWith(fgColor[i], fgVel[i], fgDepth[i]);
            ok &= lastFboOk;
        }
        genTex = colorTarget(fgTexW, fgTexH);
        genFbo = fboWith(genTex, 0);
        ok &= lastFboOk;
        if (fgNative != 0 && fgGov == 0) fgGov = MabaNative.govCreate(panelHz);
        fgReady = ok;
        fgWriteSlot = 0;
        fgHavePrev = false;
        Log.i(TAG, "Frame Gen resources: " + (ok ? "ready" : "NOT supported (float render targets)"));
    }

    private void freeFrameGen() {
        if (genTex == 0 && fgFbo[0] == 0) return;
        GLES30.glDeleteFramebuffers(2, fgFbo, 0);
        GLES30.glDeleteFramebuffers(1, new int[]{genFbo}, 0);
        GLES30.glDeleteTextures(2, fgColor, 0);
        GLES30.glDeleteTextures(2, fgVel, 0);
        GLES30.glDeleteTextures(2, fgDepth, 0);
        GLES30.glDeleteTextures(1, new int[]{genTex}, 0);
        Arrays.fill(fgColor, 0); Arrays.fill(fgVel, 0); Arrays.fill(fgDepth, 0); Arrays.fill(fgFbo, 0);
        genTex = genFbo = 0;
        fgReady = false;
    }

    @Override
    public void onSurfaceChanged(GL10 unused, int width, int height) {
        // The surface can change size more than once; drop the previous targets first.
        if (sceneTex != 0) {
            GLES30.glDeleteFramebuffers(2, sceneFbo, 0);
            GLES30.glDeleteFramebuffers(2, resolveFbo, 0);
            GLES30.glDeleteFramebuffers(1, new int[]{outFbo}, 0);
            GLES30.glDeleteTextures(2, depthTex, 0);
            GLES30.glDeleteTextures(2, resolveTex, 0);
            GLES30.glDeleteTextures(3, new int[]{sceneTex, outTex, outDepthTex}, 0);
            if (tVel != 0) {
                GLES30.glDeleteFramebuffers(2, tFbo, 0);
                GLES30.glDeleteTextures(1, new int[]{tVel}, 0);
                Arrays.fill(tFbo, 0);
                tVel = 0;
            }
            if (srFbo[0] != 0) {
                GLES30.glDeleteFramebuffers(2, srFbo, 0);
                GLES30.glDeleteTextures(2, srTex, 0);
                GLES30.glDeleteTextures(1, new int[]{srShown}, 0);
                Arrays.fill(srFbo, 0);
                Arrays.fill(srTex, 0);
                srShown = 0;
            }
        }
        freeFrameGen();
        outW = width;
        outH = height;
        if (dyn instanceof MabaNativeController) ((MabaNativeController) dyn).setOutSize(width, height);
        // Sized for the top of the ladder (scale 1.00 = the output size), so no range setting can ever
        // ask for a render region larger than the texture.
        texW = width;
        texH = height;
        Log.i(TAG, "output " + outW + "x" + outH + ", scene texture " + texW + "x" + texH);

        sceneTex = colorTarget(texW, texH);
        for (int i = 0; i < 2; i++) {
            depthTex[i] = depthTarget(texW, texH);
            sceneFbo[i] = fboWith(sceneTex, depthTex[i]);
            resolveTex[i] = colorTarget(texW, texH);
            resolveFbo[i] = fboWith(resolveTex[i], 0);
        }
        // The off-screen output needs its own depth buffer: the Native benchmark renders the 3D
        // scene straight into it, and without one the depth test silently does nothing.
        // Temporal tier with per-object motion vectors: scene + RG16F velocity + depth.
        temporalVelocity = getIntent().getIntExtra("tvel", 1) == 1 && progSceneFg != 0 && progBgFg != 0;
        if (temporalVelocity) {
            tVel = halfFloatTarget(texW, texH, GLES30.GL_RG16F, GLES30.GL_RG);
            for (int i = 0; i < 2; i++) {
                tFbo[i] = fgFboWith(sceneTex, tVel, depthTex[i]);
                temporalVelocity &= lastFboOk;
            }
            if (!temporalVelocity) Log.w(TAG, "Temporal: motion-vector targets unsupported, using camera-only reprojection");
        }
        outTex = colorTarget(outW, outH);
        outDepthTex = depthTarget(outW, outH);
        outFbo = fboWith(outTex, outDepthTex);
        if (progTsr != 0 && progTsrPresent != 0) {
            // Half-float history: colour plus the accumulated filter weight in alpha, LINEAR for reprojection.
            boolean srOk = true;
            srShown = colorTarget(outW, outH);
            for (int i = 0; i < 2; i++) {
                srTex[i] = halfFloatTarget(outW, outH, GLES30.GL_RGBA16F, GLES30.GL_RGBA);
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srTex[i]);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
                srFbo[i] = fgFboWith(srTex[i], srShown, 0);       // history + the image to show
                srOk &= lastFboOk;
            }
            if (!srOk) {
                Log.w(TAG, "Temporal SR: half-float history unsupported, using the render-resolution path");
                GLES30.glDeleteFramebuffers(2, srFbo, 0);
                GLES30.glDeleteTextures(2, srTex, 0);
                GLES30.glDeleteTextures(1, new int[]{srShown}, 0);
                Arrays.fill(srFbo, 0);
                Arrays.fill(srTex, 0);
                srShown = 0;
            }
        }
        leanHave = false;
        allocFrameGen();
        if (fgNative != 0) MabaNative.fgInvalidate(fgNative);
        temporal.reset();
        havePrevVP = false;
        lastRung = NO_RUNG;
    }

    // ---------------------------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------------------------

    // ---- Tile-memory discipline (matters on tiled mobile GPUs) --------------------------------
    // A bound framebuffer is LOADED into tile memory before drawing and STORED afterwards unless
    // told otherwise. Targets that the next pass overwrites completely must be invalidated up
    // front (no load), and depth nobody reads must be invalidated after drawing (no store).
    // Measured on the test phone: a draw into an un-invalidated target cost 6-8 ms regardless of
    // how many pixels it covered.
    private final int[] invColor0 = {GLES30.GL_COLOR_ATTACHMENT0};
    private final int[] invColor01 = {GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_COLOR_ATTACHMENT1};
    private final int[] invColorDepth = {GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_DEPTH_ATTACHMENT};
    private final int[] invDepth = {GLES30.GL_DEPTH_ATTACHMENT};
    private final int[] invWin = {GLES30.GL_COLOR, GLES30.GL_DEPTH, GLES30.GL_STENCIL};

    /** The bound framebuffer will be overwritten completely: do not load its colour. */
    private void discardColor(int fbo, boolean alsoDepth) {
        if (fbo == 0) GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, invWin.length, invWin, 0);
        else if (alsoDepth) GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 2, invColorDepth, 0);
        else GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 1, invColor0, 0);
    }

    private void fullscreenPass(int prog, int dstFbo, int w, int h) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, w, h);
        GLES30.glUseProgram(prog);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    /** Camera eye: slow orbit with a gentle dolly in/out and height drift. */
    /** Where the camera is: the touch camera when it is in control (never during the scripted quality checks), else the auto orbit. */
    private float[] cameraEye(float time) {
        if (camUser && !qcRunning && !dumpMode) {
            final float cp = (float) Math.cos(camPitch);
            return new float[]{camDist * cp * (float) Math.sin(camYaw), CAM_TARGET_Y + camDist * (float) Math.sin(camPitch),
                camDist * cp * (float) Math.cos(camYaw)};
        }
        return autoEye(time);
    }

    private static float[] autoEye(float time) {
        float ang = time * 0.12f + 0.6f;
        // Stays well inside the pillar circle (Scene3D.PILLAR_R minus the plinth size).
        float radius = 4.6f + 0.6f * (float) Math.sin(time * 0.19f);
        float height = 1.0f + 0.55f * (float) Math.sin(time * 0.15f + 1.0f);
        return new float[]{radius * (float) Math.sin(ang), height, radius * (float) Math.cos(ang)};
    }

    private Mat4 cameraVP(float time, int rw, int rh, float jx, float jy) {
        float[] e = cameraEye(time);
        Mat4 view = Mat4.lookAt(e[0], e[1], e[2], 0, CAM_TARGET_Y, 0);
        Mat4 proj = Mat4.perspective(48f * (float) Math.PI / 180f, (float) rw / rh, 0.1f, 40f);
        if (jx != 0f || jy != 0f) proj.applyJitter(jx, jy, rw, rh);
        return Mat4.mul(proj, view);
    }

    /** Background + 3D scene into the scene FBO at region size. */
    private void drawScene3D(int dstFbo, int rw, int rh, float time, Mat4 vp, boolean keepDepth) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        GLES30.glViewport(0, 0, rw, rh);
        discardColor(dstFbo, false);   // the sky and the scene cover every pixel
        GLES30.glDepthMask(true);
        GLES30.glClear(GLES30.GL_DEPTH_BUFFER_BIT);

        GLES30.glEnable(GLES30.GL_DEPTH_TEST);
        GLES30.glDepthFunc(GLES30.GL_LEQUAL);
        GLES30.glUseProgram(progScene);
        GLES30.glUniformMatrix4fv(uloc(progScene, "uVP"), 1, false, vp.m, 0);
        float[] eye = cameraEye(time);
        GLES30.glUniform3f(uloc(progScene, "uCamPos"), eye[0], eye[1], eye[2]);
        GLES30.glUniform1f(uloc(progScene, "uTime"), shadeTime(time));
        GLES30.glUniform1i(uloc(progScene, "uLoad"), load);
        scene.draw(progScene, time);
        drawSkyBehindScene(progBg);
        // Depth is only read by the temporal resolve; everywhere else do not write it to memory.
        if (!keepDepth) {
            if (dstFbo == 0) GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 2,
                new int[]{GLES30.GL_DEPTH, GLES30.GL_STENCIL}, 0);
            else GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 1, invDepth, 0);
        }
    }

    /**
     * The sky, drawn AFTER the scene at the far plane: depth range (1,1) puts every sky fragment
     * at depth 1, so the depth test keeps only pixels the scene did not cover and the sky shader
     * runs nowhere else. Leaves the depth test off.
     */
    private void drawSkyBehindScene(int prog) {
        GLES30.glDepthMask(false);
        GLES30.glDepthRangef(1f, 1f);
        GLES30.glUseProgram(prog);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        GLES30.glDepthRangef(0f, 1f);
        GLES30.glDepthMask(true);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
    }

    private void upscale(int srcTex, int prog, int dstFbo, int rw, int rh) {
        upscale(srcTex, prog, dstFbo, rw, rh, texW, texH);
    }

    /** srcW x srcH is the size of the source TEXTURE (the image occupies its rw x rh corner). */
    private void upscale(int srcTex, int prog, int dstFbo, int rw, int rh, int srcW, int srcH) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        discardColor(dstFbo, dstFbo == outFbo);   // outFbo also carries a depth texture nobody reads here
        GLES30.glViewport(0, 0, outW, outH);
        GLES30.glUseProgram(prog);
        GLES30.glUniform4f(uloc(prog, "uMabaInputSize"), rw, rh, 1f / srcW, 1f / srcH);
        GLES30.glUniform4f(uloc(prog, "uMabaParams"), sharpness, 0, 0, 0);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTex);
        GLES30.glUniform1i(uloc(prog, "uMabaInput"), 0);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    /**
     * Temporal scene pass with motion vectors: the scene and the sky write colour, depth and the
     * jitter-free per-pixel motion (camera and objects) since the previous frame.
     */
    private void drawSceneVelocity(int slot, int rw, int rh, float time, Mat4 jittered, Mat4 plain, Mat4 plainInv) {
        float prevT = havePrevVP ? tPrevTime : -1f;
        Mat4 prevPlain = havePrevVP ? prevVP : plain;
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, tFbo[slot]);
        GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 2, invColor01, 0);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glDepthMask(true);
        GLES30.glClear(GLES30.GL_DEPTH_BUFFER_BIT);
        GLES30.glEnable(GLES30.GL_DEPTH_TEST);
        GLES30.glDepthFunc(GLES30.GL_LEQUAL);
        GLES30.glUseProgram(progSceneFg);
        GLES30.glUniformMatrix4fv(uloc(progSceneFg, "uVP"), 1, false, jittered.m, 0);
        GLES30.glUniformMatrix4fv(uloc(progSceneFg, "uPrevVP"), 1, false, prevPlain.m, 0);
        GLES30.glUniform2f(uloc(progSceneFg, "uJitter"),
            2f * curJitterX / rw, 2f * curJitterY / rh);
        float[] eye = cameraEye(time);
        GLES30.glUniform3f(uloc(progSceneFg, "uCamPos"), eye[0], eye[1], eye[2]);
        GLES30.glUniform1f(uloc(progSceneFg, "uTime"), shadeTime(time));
        GLES30.glUniform1i(uloc(progSceneFg, "uLoad"), load);
        scene.draw(progSceneFg, time, prevT);
        GLES30.glUseProgram(progBgFg);
        GLES30.glUniformMatrix4fv(uloc(progBgFg, "uInvVP"), 1, false, plainInv.m, 0);
        GLES30.glUniformMatrix4fv(uloc(progBgFg, "uPrevVP"), 1, false, prevPlain.m, 0);
        GLES30.glUniform2f(uloc(progBgFg, "uJitterUV"), curJitterX / rw, curJitterY / rh);
        drawSkyBehindScene(progBgFg);
        tPrevTime = time;
    }

    /** Temporal resolve at region size; writes resolveTex[slot]. */
    private float curJitterX, curJitterY;

    /** Developer extra tnoshade=1: freeze the time-varying SHADING (pulses, plasma) while geometry still moves. */
    private float shadeTime(float time) {
        return devNoShade ? 20f : time;
    }

    private void temporalResolve(int rw, int rh, Mat4 invVP, float reset) {
        int prev = 1 - slot;
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, resolveFbo[slot]);
        GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 1, invColor0, 0);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glUseProgram(progTemporal);
        int p = progTemporal;
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, sceneTex);
        GLES30.glUniform1i(uloc(p, "uMabaInput"), 0);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, resolveTex[prev]);
        GLES30.glUniform1i(uloc(p, "uMabaHistory"), 1);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE2);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTex[slot]);
        GLES30.glUniform1i(uloc(p, "uMabaDepth"), 2);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE3);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTex[prev]);
        GLES30.glUniform1i(uloc(p, "uMabaPrevDepth"), 3);
        GLES30.glUniformMatrix4fv(uloc(p, "uMabaInvViewProj"), 1, false, invVP.m, 0);
        GLES30.glUniformMatrix4fv(uloc(p, "uMabaPrevViewProj"), 1, false, prevVP.m, 0);
        float[] params = temporal.uniforms(reset);
        GLES30.glUniform4f(uloc(p, "uMabaTemporalParams"),
            params[0], params[1], params[2], params[3]);
        GLES30.glUniform2f(uloc(p, "uMabaTexel"), 1f / texW, 1f / texH);
        GLES30.glUniform2f(uloc(p, "uMabaRegion"), rw, rh);
        GLES30.glUniform2f(uloc(p, "uMabaJitter"), curJitterX, curJitterY);
        if (temporalVelocity) {
            bindTex(p, "uMabaVelocity", 4, tVel);
            GLES30.glUniform2f(uloc(p, "uMabaDepthRange"), CAM_NEAR, CAM_FAR);
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        }
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
    }

    /** Temporal SR resolve at OUTPUT resolution: writes srTex[slot] from the jittered render frame. */
    private void temporalSR(int rw, int rh, float reset) {
        int prev = 1 - slot;
        int p = progTsr;
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, srFbo[slot]);
        GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 2, invColor01, 0);
        GLES30.glViewport(0, 0, outW, outH);
        GLES30.glUseProgram(p);
        bindTex(p, "uMabaInput", 0, sceneTex);
        bindTex(p, "uMabaHistory", 1, srTex[prev]);
        bindTex(p, "uMabaDepth", 2, depthTex[slot]);
        bindTex(p, "uMabaPrevDepth", 3, depthTex[prev]);
        bindTex(p, "uMabaVelocity", 4, tVel);
        float[] params = temporal.uniforms(reset);
        GLES30.glUniform4f(uloc(p, "uMabaTemporalParams"),
            params[0], params[1], params[2], params[3]);
        GLES30.glUniform2f(uloc(p, "uMabaTexel"), 1f / texW, 1f / texH);
        GLES30.glUniform2f(uloc(p, "uMabaRegion"), rw, rh);
        GLES30.glUniform4f(uloc(p, "uMabaOut"), outW, outH, 1f / outW, 1f / outH);
        GLES30.glUniform2f(uloc(p, "uMabaJitter"), curJitterX, curJitterY);
        GLES30.glUniform2f(uloc(p, "uMabaDepthRange"), CAM_NEAR, CAM_FAR);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
    }

    /** Shows the accumulated image: a 5-tap sharpen clamped to the local range (never fed back). */
    private void tsrPresent(int dstFbo) {
        int p = progTsrPresent;
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        discardColor(dstFbo, dstFbo == outFbo);
        GLES30.glViewport(0, 0, outW, outH);
        GLES30.glUseProgram(p);
        bindTex(p, "uMabaInput", 0, srShown);
        GLES30.glUniform4f(uloc(p, "uMabaOut"), outW, outH, 1f / outW, 1f / outH);
        GLES30.glUniform1f(uloc(p, "uMabaSharp"),
            tsrSharpAbs >= 0f ? tsrSharpAbs : sharpness * 0.12f);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
    }

    /** One full frame of the given mode into dstFbo. Returns the rung used. */
    private int drawMode(int m, int rung, int dstFbo, float time) {
        if (isNativeFrame(m, rung)) {
            // Scale 1.00: render at output size straight into the destination, no upscale pass.
            Mat4 vp = cameraVP(time, outW, outH, 0, 0);
            drawScene3D(dstFbo, outW, outH, time, vp, false);
            return MabaController.RUNG_CEIL;
        }
        int rw = Math.max(2, Math.round(outW * MabaController.rungScale(rung)));
        int rh = Math.max(2, Math.round(outH * MabaController.rungScale(rung)));
        boolean temporalMode = m == TEMPORAL && progTemporal != 0;

        if (temporalMode) {
            if (rung != lastRung) { temporal.reset(); havePrevVP = false; }
            lastRung = rung;
            float[] jf = temporal.beginFrame();
            curJitterX = jf[0];
            curJitterY = jf[1];
            Mat4 jittered = cameraVP(time, rw, rh, jf[0], jf[1]);
            Mat4 plain = cameraVP(time, rw, rh, 0, 0);
            Mat4 inv = plain.invert();
            if (inv == null) inv = Mat4.identity();
            float reset = (jf[2] > 0.5f || !havePrevVP) ? 1f : 0f;
            if (temporalVelocity) drawSceneVelocity(slot, rw, rh, time, jittered, plain, inv);
            else drawScene3D(sceneFbo[slot], rw, rh, time, jittered, true);
            final boolean sr = tsrActive();
            if (sr) temporalSR(rw, rh, reset);
            else temporalResolve(rw, rh, inv, reset);
            // History is reprojected with the UNJITTERED matrix: it holds the accumulated,
            // jitter-free image, so a jittered matrix would blur it a little every frame.
            System.arraycopy(plain.m, 0, prevVP.m, 0, 16);
            havePrevVP = true;
            if (sr) {
                tsrPresent(dstFbo);
            } else {
                int prog = MabaController.rungQuality(rung) ? progQuality : progFast;
                upscale(resolveTex[slot], prog, dstFbo, rw, rh);
            }
            slot = 1 - slot;
        } else {
            Mat4 vp = cameraVP(time, rw, rh, 0, 0);
            drawScene3D(sceneFbo[0], rw, rh, time, vp, false);
            int prog = m == BILINEAR ? progBlit
                : (MabaController.rungQuality(rung) ? progQuality : progFast);
            upscale(sceneTex, prog, dstFbo, rw, rh);
        }
        return rung;
    }

    // ---------------------------------------------------------------------------------------
    // MABA Frame Gen (2x): real frame -> generated frame -> real frame -> ...
    //
    // A real frame renders the scene with motion vectors (camera AND per-object, plus the sky).
    // The generated frame that follows is built from that real frame alone by the warp passes of
    // maba_framegen.frag.glsl: extrapolated half a real-frame interval forward. Nothing waits for
    // the next real frame, so frame generation adds no waiting latency. Both kinds of frame go
    // through the normal MABA upscale to the screen.
    // ---------------------------------------------------------------------------------------

    private void bindTex(int prog, String uniform, int unit, int tex) {
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex);
        GLES30.glUniform1i(uloc(prog, uniform), unit);
    }

    /** Real frame: sky + scene into FG slot `slot` (colour, motion vectors, depth). */
    private void fgRenderReal(int slot, int rw, int rh, float time, float prevTime) {
        Mat4 vp = cameraVP(time, rw, rh, 0, 0);
        Mat4 prevVp = prevTime < 0f ? vp : cameraVP(prevTime, rw, rh, 0, 0);
        Mat4 inv = vp.invert();
        if (inv == null) inv = Mat4.identity();

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fgFbo[slot]);
        GLES30.glInvalidateFramebuffer(GLES30.GL_FRAMEBUFFER, 2, invColor01, 0);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glDepthMask(true);
        GLES30.glClear(GLES30.GL_DEPTH_BUFFER_BIT);

        GLES30.glEnable(GLES30.GL_DEPTH_TEST);
        GLES30.glDepthFunc(GLES30.GL_LEQUAL);
        GLES30.glUseProgram(progSceneFg);
        GLES30.glUniformMatrix4fv(uloc(progSceneFg, "uVP"), 1, false, vp.m, 0);
        GLES30.glUniformMatrix4fv(uloc(progSceneFg, "uPrevVP"), 1, false, prevVp.m, 0);
        float[] eye = cameraEye(time);
        GLES30.glUniform3f(uloc(progSceneFg, "uCamPos"), eye[0], eye[1], eye[2]);
        GLES30.glUniform1f(uloc(progSceneFg, "uTime"), shadeTime(time));
        GLES30.glUniform1i(uloc(progSceneFg, "uLoad"), load);
        scene.draw(progSceneFg, time, prevTime);

        GLES30.glUseProgram(progBgFg);
        GLES30.glUniformMatrix4fv(uloc(progBgFg, "uInvVP"), 1, false, inv.m, 0);
        GLES30.glUniformMatrix4fv(uloc(progBgFg, "uPrevVP"), 1, false, prevVp.m, 0);
        drawSkyBehindScene(progBgFg);
    }

    private void fgSizeUniforms(int prog, int rw, int rh) {
        GLES30.glUniform4f(uloc(prog, "uMabaFgSize"), rw, rh, 1f / fgTexW, 1f / fgTexH);
    }

    /** Generated frame: one warp pass of the newest real frame into genTex. */
    private void fgGenerate() {
        fgGenerate(genFbo);
    }

    /** The warp pass into dstFbo (genFbo, or 0 = straight to the window when no upscale follows). */
    private void fgGenerate(int dstFbo) {
        int cur = fgCurSlot, prev = 1 - cur;
        int rw = fgCurRw, rh = fgCurRh;
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, dstFbo);
        discardColor(dstFbo, false);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glUseProgram(progFgWarp);
        fgSizeUniforms(progFgWarp, rw, rh);
        GLES30.glUniform4f(uloc(progFgWarp, "uMabaFgPrevSize"),
            fgPrevRw, fgPrevRh, 1f / fgTexW, 1f / fgTexH);
        GLES30.glUniform4f(uloc(progFgWarp, "uMabaFgParams"),
            qcRunning ? devQfgOff : ((fgActive && fgNative != 0) ? MabaNative.fgGenOffset(fgNative) : 0.5f),   // 1/2 at 2x; 1/3, 2/3 at 3x
            CAM_NEAR, CAM_FAR, devFgK);   // devFgK 0 = automatic scale
        bindTex(progFgWarp, "uMabaColor", 0, fgColor[cur]);
        bindTex(progFgWarp, "uMabaVelocity", 1, fgVel[cur]);
        bindTex(progFgWarp, "uMabaDepth", 2, fgDepth[cur]);
        bindTex(progFgWarp, "uMabaPrevColor", 3, fgColor[prev]);
        bindTex(progFgWarp, "uMabaPrevDepth", 4, fgDepth[prev]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);

        // Leave nothing bound that a later pass could read while writing it.
        for (int u = 1; u <= 4; u++) {
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + u);
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0);
        }
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
    }
    /**
     * Frame Gen on the lean temporal pipeline. A real frame is the full temporal upscale, kept in outTex (and shown);
     * a generated frame warps that FINISHED, sharpened, display-resolution image with the real frame's motion vectors
     * and depth (render resolution), so generated frames keep the quality of the temporal upscale. The previous
     * accumulated image serves disocclusions.
     */
    private int drawLeanFrameGen(int kind, float animTime) {
        int rung = presetRung();
        pollReset();
        fgShownKind = kind;
        if (kind == FG_REAL || !leanHave) {
            drawMode(TEMPORAL, rung, outFbo, animTime);          // slot flips inside
            float sc = MabaController.rungScale(rung);
            fgLeanRw = Math.max(2, Math.round(outW * sc));
            fgLeanRh = Math.max(2, Math.round(outH * sc));
            leanHave = true;
            blitOutToWindow();
            return rung;
        }
        float h = MabaNative.fgGenOffset(fgNative);
        int cur = 1 - slot, prev = slot;
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0);
        GLES30.glViewport(0, 0, outW, outH);
        int p = progFgWarpHi;
        GLES30.glUseProgram(p);
        GLES30.glUniform4f(uloc(p, "uMabaFgSize"), fgLeanRw, fgLeanRh, 1f / texW, 1f / texH);
        GLES30.glUniform4f(uloc(p, "uMabaFgPrevSize"), fgLeanRw, fgLeanRh, 1f / texW, 1f / texH);
        GLES30.glUniform4f(uloc(p, "uMabaFgColorSize"), outW, outH, 1f / outW, 1f / outH);
        GLES30.glUniform4f(uloc(p, "uMabaFgOut"), outW, outH, 1f / outW, 1f / outH);
        GLES30.glUniform4f(uloc(p, "uMabaFgParams"), h, CAM_NEAR, CAM_FAR, devFgK);
        bindTex(p, "uMabaColor", 0, outTex);
        bindTex(p, "uMabaVelocity", 1, tVel);
        bindTex(p, "uMabaDepth", 2, depthTex[cur]);
        bindTex(p, "uMabaPrevColor", 3, srTex[prev]);
        bindTex(p, "uMabaPrevDepth", 4, depthTex[prev]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        unbindUnits(4);
        return rung;
    }

    private void unbindUnits(int last) {
        for (int u = 1; u <= last; u++) {
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + u);
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0);
        }
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
    }

    private void blitOutToWindow() {
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, outFbo);
        GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0);
        GLES30.glBlitFramebuffer(0, 0, outW, outH, 0, 0, outW, outH,
            GLES30.GL_COLOR_BUFFER_BIT, GLES30.GL_NEAREST);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0);
    }

    /**
     * One Frame Gen frame (real or generated) through the MABA upscale. dst: 0 = straight to the
     * window; 1 = timed (off-screen with glFinish, then copied to the window); 2 = off-screen
     * and timed with glFinish (latency, includes fixed driver latency); 3 = off-screen, untimed,
     * for throughput loops. Returns the milliseconds when timed (dst 1 or 2), else -1.
     */
    private float fgDrawSlot(int kind, int m, int rung, float time, int dst) {
        boolean timed = dst == 1 || dst == 2;
        long t0 = 0;
        if (timed) { GLES30.glFinish(); t0 = System.nanoTime(); }

        final boolean nativeRes = isNativeFrame(m, rung);   // no upscaling: frames are already screen-sized
        int src, sw, sh;
        if (kind == FG_REAL) {
            int rw = Math.max(2, Math.round(outW * MabaController.rungScale(rung)));
            int rh = Math.max(2, Math.round(outH * MabaController.rungScale(rung)));
            int slot = fgWriteSlot;
            fgRenderReal(slot, rw, rh, time, fgHavePrev ? fgPrevTime : -1f);
            fgPrevRw = fgHavePrev ? fgCurRw : rw;
            fgPrevRh = fgHavePrev ? fgCurRh : rh;
            fgCurSlot = slot; fgCurRw = rw; fgCurRh = rh;
            fgPrevTime = time;
            fgHavePrev = true;
            fgWriteSlot = 1 - slot;
            src = fgColor[slot]; sw = rw; sh = rh;
        } else if (fgDbg == 1) {
            src = fgColor[fgCurSlot]; sw = fgCurRw; sh = fgCurRh;   // developer: repeat, no warp
        } else {
            // Native: the warp is the last pass, so it writes the window directly. Only when the real
            // frame it warps is screen-sized; anything else goes through the normal upscale, so a
            // stale smaller size can never leave a picture in one corner of the window.
            if (nativeRes && dst == 0 && fgCurRw == outW && fgCurRh == outH) {
                fgGenerate(0);
                return -1f;
            }
            fgGenerate();
            src = genTex; sw = fgCurRw; sh = fgCurRh;
        }
        int prog = (m == BILINEAR || nativeRes) ? progBlit
            : (MabaController.rungQuality(rung) ? progQuality : progFast);

        if (dst == 0) {
            upscale(src, prog, 0, sw, sh, fgTexW, fgTexH);
            return -1f;
        }
        if (dst == 3) {
            upscale(src, prog, outFbo, sw, sh, fgTexW, fgTexH);
            return -1f;
        }
        upscale(src, prog, outFbo, sw, sh, fgTexW, fgTexH);
        GLES30.glFinish();
        float ms = (System.nanoTime() - t0) / 1e6f;
        if (dst == 1) blitOutToWindow();
        return ms;
    }

    // ---------------------------------------------------------------------------------------
    // Quality checks. Run once after the benchmark, ONE SAMPLE PER DISPLAYED FRAME on a centre
    // crop, so the screen keeps moving (the earlier version did all of it in one frame and froze
    // the app for 1.6 s). Two objective measurements, both against a true render:
    //   - Frame Gen: a generated frame versus a real render of the instant it stands for, next to
    //     the alternative without Frame Gen (showing the last real frame again).
    //   - Upscaler: the scene at 0.59 render scale upscaled three ways, versus a native render.
    // ---------------------------------------------------------------------------------------
    private static final int QC_FG_SAMPLES = 4, QC_UP_SAMPLES = 3;
    private int QC_TEMPORAL_FRAMES = 12;                      // one full Halton cycle is 16; --ei qtf N overrides
    // Render scales measured: the Balanced one by default, all four presets with --ei qsweep 1.
    private int[] qcRungs = {10};
    private static final int[] QC_SWEEP_RUNGS = {0, 10, 18, 28};
    // Sub-steps per sample: the reference, then per scale one spatial step and the Temporal
    // frames, then the native render (the ceiling: aliased, no upscaling).
    private int qcUpSubs() { return 1 + qcRungs.length * (1 + QC_TEMPORAL_FRAMES) + 1; }
    private final double[][] qcMse = new double[4][4];          // [scale][bilinear, fast, quality, temporal]
    private final double[][] qcGrad = new double[4][4];         // gradient energy of each output
    private double qcNativeMse, qcNativeGrad, qcRefGrad;
    private int ssFbo, ssColor, ssDepth;
    private String fgQualityText = "", upQualityText = "";
    private int qcStep;
    private boolean qcRunning;
    private final double[][] qcFg = new double[2][4];     // per group (extrapolate 1x, 6x): mseGen, mseRep, okGen, okRep
    private final long[] qcFgPx = new long[2];
    private final double[][] qcFgBlur = new double[2][2];  // the same, after a 4x4 box filter: mseGen, mseRep
    private final long[] qcFgBlurPx = new long[2];
    private long qcUpPx;

    // Each sample is split into small sub-steps (3 for Frame Gen, 2 for the upscaler), one per
    // displayed frame, so no single frame carries much extra work.
    private int qcSample, qcSub;
    private byte[] qcRef;

    private int qcFgGroups() { return 2; }
    private int qcSteps() { return (fgReady ? qcFgGroups() * QC_FG_SAMPLES * 3 : 0) + QC_UP_SAMPLES * qcUpSubs(); }

    /** Starts (or restarts) the quality run with empty accumulators. */
    private void startQualityRun() {
        for (double[] a : qcMse) Arrays.fill(a, 0);
        for (double[] a : qcGrad) Arrays.fill(a, 0);
        for (double[] a : qcFg) Arrays.fill(a, 0);
        for (double[] a : qcFgBlur) Arrays.fill(a, 0);
        Arrays.fill(qcFgPx, 0);
        Arrays.fill(qcFgBlurPx, 0);
        qcNativeMse = qcNativeGrad = qcRefGrad = 0;
        qcUpPx = 0;
        qcStep = 0; qcSample = 0; qcSub = 0;
        qcRunning = true;
    }

    /** Reads a rectangle of the colour attachment 0 of fbo. */
    private byte[] readRegion(int fbo, int x, int y, int w, int h) {
        ByteBuffer b = ByteBuffer.allocateDirect(w * h * 4);
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, fbo);
        GLES30.glReadBuffer(GLES30.GL_COLOR_ATTACHMENT0);
        GLES30.glReadPixels(x, y, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, b);
        byte[] a = new byte[w * h * 4];
        b.position(0);
        b.get(a);
        return a;
    }

    private static double psnr(double mse, long samples) {
        return 10.0 * Math.log10(255.0 * 255.0 / Math.max(1e-9, mse / samples));
    }

    /** One quality sub-step; returns true when all are done. */
    private boolean qualityStep() {
        int fgSamples = fgReady ? qcFgGroups() * QC_FG_SAMPLES : 0;
        boolean fgPhase = qcSample < fgSamples;
        if (fgPhase) { int grp = qcSample / QC_FG_SAMPLES; fgQualitySample(grp % 2 == 0 ? 1f : 6f, qcSample % QC_FG_SAMPLES, grp, qcSub); }
        else upscalerQualitySample(qcSample - fgSamples, qcSub);
        qcStep++;
        if (++qcSub >= (fgPhase ? 3 : qcUpSubs())) { qcSub = 0; qcSample++; }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0);
        return qcSample >= fgSamples + QC_UP_SAMPLES;
    }

    private void fgQualitySample(float speed, int k, int si, int sub) {
        final int rung = devQfgRung;
        final int rw = Math.max(2, Math.round(outW * MabaController.rungScale(rung)));
        final int rh = Math.max(2, Math.round(outH * MabaController.rungScale(rung)));
        final float dt = speed / 30f;      // speed 6 = everything moves 6x as far per real frame
        float tA = 6f + k * 5.3f, tB = tA + dt;
        if (sub == 0) {
            fgRenderReal(0, rw, rh, tA, -1f);
            fgRenderReal(1, rw, rh, tB, tA);
        } else if (sub == 1) {
            fgCurSlot = 1; fgCurRw = rw; fgCurRh = rh; fgPrevRw = rw; fgPrevRh = rh;
            fgGenerate();
            fgRenderReal(0, rw, rh, tB + dt * devQfgOff, tB);         // the truth, into the now-unused slot
        } else {
            int cw = Math.min(rw, 384), ch = Math.min(rh, 216), cx = (rw - cw) / 2, cy = (rh - ch) / 2;
            byte[] gen = readRegion(genFbo, cx, cy, cw, ch);
            byte[] truth = readRegion(fgFbo[0], cx, cy, cw, ch);
            byte[] rep = readRegion(fgFbo[1], cx, cy, cw, ch);
            double mseG = 0, mseR = 0;
            long okG = 0, okR = 0;
            for (int i = 0; i < cw * ch; i++) {
                int worstG = 0, worstR = 0;
                for (int c = 0; c < 3; c++) {
                    int tv = truth[i * 4 + c] & 0xFF;
                    int dg = Math.abs((gen[i * 4 + c] & 0xFF) - tv);
                    int dr = Math.abs((rep[i * 4 + c] & 0xFF) - tv);
                    mseG += (double) dg * dg;
                    mseR += (double) dr * dr;
                    if (dg > worstG) worstG = dg;
                    if (dr > worstR) worstR = dr;
                }
                if (worstG <= 8) okG++;
                if (worstR <= 8) okR++;
            }
            if (getIntent().getIntExtra("qcdump", 0) == 1 && k == 0) {
                dumpPpm("fg" + si + "_gen", gen, cw, ch);
                dumpPpm("fg" + si + "_truth", truth, cw, ch);
                dumpPpm("fg" + si + "_rep", rep, cw, ch);
            }
            qcFg[si][0] += mseG; qcFg[si][1] += mseR; qcFg[si][2] += okG; qcFg[si][3] += okR;
            qcFgPx[si] += (long) cw * ch;
            // The same comparison after a 4x4 box filter: tests where things are, not how their sub-pixel aliasing falls.
            for (int by = 0; by + 4 <= ch; by += 4) {
                for (int bx = 0; bx + 4 <= cw; bx += 4) {
                    for (int c = 0; c < 3; c++) {
                        int sg = 0, sr = 0, st = 0;
                        for (int yy = 0; yy < 4; yy++) {
                            for (int xx = 0; xx < 4; xx++) {
                                int i = ((by + yy) * cw + bx + xx) * 4 + c;
                                sg += gen[i] & 0xFF; sr += rep[i] & 0xFF; st += truth[i] & 0xFF;
                            }
                        }
                        double dg = (sg - st) / 16.0, dr = (sr - st) / 16.0;
                        qcFgBlur[si][0] += dg * dg; qcFgBlur[si][1] += dr * dr;
                    }
                }
            }
            qcFgBlurPx[si] += (long) (cw / 4) * (ch / 4);
            fgHavePrev = false;
            fgWriteSlot = 0;
        }
    }

    /** Developer: writes an RGBA readback (bottom-up) as a PPM into the app's external files folder. */
    private void dumpPpm(String name, byte[] rgba, int w, int h) {
        File f = new File(getExternalFilesDir(null), name + ".ppm");
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(("P6\n" + w + " " + h + "\n255\n").getBytes("UTF-8"));
            byte[] row = new byte[w * 3];
            for (int y = h - 1; y >= 0; y--) {
                for (int x = 0; x < w; x++) {
                    int i = (y * w + x) * 4;
                    row[x * 3] = rgba[i]; row[x * 3 + 1] = rgba[i + 1]; row[x * 3 + 2] = rgba[i + 2];
                }
                out.write(row);
            }
        } catch (Exception e) {
            Log.e(TAG, "dump failed", e);
        }
    }

    private void ensureSupersampleTarget() {
        if (ssFbo != 0) return;
        ssColor = colorTarget(outW * 2, outH * 2);
        ssDepth = depthTarget(outW * 2, outH * 2);
        ssFbo = fboWith(ssColor, ssDepth);
    }

    private void freeSupersampleTarget() {
        if (ssFbo == 0) return;
        GLES30.glDeleteFramebuffers(1, new int[]{ssFbo}, 0);
        GLES30.glDeleteTextures(2, new int[]{ssColor, ssDepth}, 0);
        ssFbo = ssColor = ssDepth = 0;
    }

    /**
     * Image quality versus a 2x-supersampled native render (box-filtered down), which is what a
     * perfect anti-aliased image looks like; an ordinary native render is aliased and would
     * reward aliasing. sub 0 = the reference, sub 1 = the three spatial upscalers, sub 2.. = the
     * Temporal upscaler, one frame per sub-step, so its history really builds up.
     */
    private void upscalerQualitySample(int k, int sub) {
        float t = 8f + k * 7.1f;
        int cw = Math.min(outW, 512), ch = Math.min(outH, 256), cx = (outW - cw) / 2, cy = (outH - ch) / 2;
        final int perRung = 1 + QC_TEMPORAL_FRAMES;
        if (sub == 0) {
            ensureSupersampleTarget();
            drawScene3D(ssFbo, outW * 2, outH * 2, t, cameraVP(t, outW * 2, outH * 2, 0, 0), false);
            GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, ssFbo);
            GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, outFbo);
            GLES30.glBlitFramebuffer(0, 0, outW * 2, outH * 2, 0, 0, outW, outH,
                GLES30.GL_COLOR_BUFFER_BIT, GLES30.GL_LINEAR);      // exact 2x2 box filter
            qcRef = readRegion(outFbo, cx, cy, cw, ch);
            qcRefGrad += gradEnergy(qcRef, cw, ch);
            qcUpPx += (long) cw * ch;
            return;
        }
        if (sub == 1 + qcRungs.length * perRung) {
            // The ceiling: an ordinary native render (aliased, no upscaling) against the same reference.
            drawMode(NATIVE, MabaController.RUNG_CEIL, outFbo, t);
            byte[] px = readRegion(outFbo, cx, cy, cw, ch);
            qcNativeMse += mseAgainst(px, qcRef, cw * ch);
            qcNativeGrad += gradEnergy(px, cw, ch);
            return;
        }
        final int r = (sub - 1) / perRung, j = (sub - 1) % perRung;
        final int rung = qcRungs[r];
        final int rw = Math.max(2, Math.round(outW * MabaController.rungScale(rung)));
        final int rh = Math.max(2, Math.round(outH * MabaController.rungScale(rung)));
        if (j == 0) {
            drawScene3D(sceneFbo[0], rw, rh, t, cameraVP(t, rw, rh, 0, 0), false);
            int[] progs = {progBlit, progFast, progQuality};
            for (int v = 0; v < 3; v++) {
                upscale(sceneTex, progs[v], outFbo, rw, rh);
                byte[] px = readRegion(outFbo, cx, cy, cw, ch);
                qcMse[r][v] += mseAgainst(px, qcRef, cw * ch);
                qcGrad[r][v] += gradEnergy(px, cw, ch);
            }
            return;
        }
        if (progTemporal == 0) return;
        int i = j - 1;
        float dt = devFreeze ? 0f : 1f / 60f;   // developer: frozen scene
        float ti = t - (QC_TEMPORAL_FRAMES - 1 - i) * dt;
        if (i == 0) { temporal.reset(); havePrevVP = false; lastRung = NO_RUNG; }
        drawMode(TEMPORAL, rung, outFbo, ti);
        if (i == QC_TEMPORAL_FRAMES - 1) {
            byte[] px = readRegion(outFbo, cx, cy, cw, ch);
            qcMse[r][3] += mseAgainst(px, qcRef, cw * ch);
            qcGrad[r][3] += gradEnergy(px, cw, ch);
            temporal.reset();
            havePrevVP = false;
            lastRung = NO_RUNG;
        }
    }

    private static float lumaAt(byte[] a, int i) {
        return 0.299f * (a[i] & 0xFF) + 0.587f * (a[i + 1] & 0xFF) + 0.114f * (a[i + 2] & 0xFF);
    }

    /** Sum of luma gradient magnitudes: how much fine detail an image carries (blur lowers it). */
    private static double gradEnergy(byte[] a, int w, int h) {
        double s = 0;
        for (int y = 0; y < h - 1; y++) {
            for (int x = 0; x < w - 1; x++) {
                int i = (y * w + x) * 4;
                float l = lumaAt(a, i);
                s += Math.abs(lumaAt(a, i + 4) - l) + Math.abs(lumaAt(a, i + w * 4) - l);
            }
        }
        return s;
    }

    private static double mseAgainst(byte[] a, byte[] ref, int pixels) {
        double mse = 0;
        for (int i = 0; i < pixels; i++) {
            for (int c = 0; c < 3; c++) {
                int d = (a[i * 4 + c] & 0xFF) - (ref[i * 4 + c] & 0xFF);
                mse += (double) d * d;
            }
        }
        return mse;
    }
    private void finishQualityChecks() {
        StringBuilder fgText = new StringBuilder();
        String[] label = {"this scene", "6x faster motion"};
        if (fgReady) {
            for (int si = 0; si < qcFgGroups(); si++) {
                double px = qcFgPx[si];
                if (si > 0) fgText.append("\n");
                fgText.append(String.format(Locale.US,
                    "Frame Gen %s vs a true render of the same instant (%s, centre crop): generated frame %.1f dB, "
                    + "%.1f%% of pixels within 8/255; repeating the real frame instead: %.1f dB, %.1f%%; "
                    + "after a 4x4 box filter: generated %.1f dB, repeating %.1f dB",
                    "extrapolated", label[si], psnr(qcFg[si][0], qcFgPx[si] * 3), 100.0 * qcFg[si][2] / px,
                    psnr(qcFg[si][1], qcFgPx[si] * 3), 100.0 * qcFg[si][3] / px,
                    psnr(qcFgBlur[si][0], qcFgBlurPx[si] * 3), psnr(qcFgBlur[si][1], qcFgBlurPx[si] * 3)));
            }
        }
        fgQualityText = fgText.toString();
        freeSupersampleTarget();
        StringBuilder up = new StringBuilder(String.format(Locale.US,
            "Image quality vs a 2x-supersampled render (sharpness %.2f, %d scenes), PSNR dB / detail kept:",
            sharpness, QC_UP_SAMPLES));
        up.append(String.format(Locale.US, "\n  native render, aliased, no upscaling: %.2f dB / %.0f%%",
            psnr(qcNativeMse, qcUpPx * 3), 100.0 * qcNativeGrad / qcRefGrad));
        String[] vname = {"bilinear", "MABA fast", "MABA quality", "MABA Temporal"};
        for (int r = 0; r < qcRungs.length; r++) {
            up.append(String.format(Locale.US, "\n  scale %.2f:", MabaController.rungScale(qcRungs[r])));
            for (int v = 0; v < 4; v++) {
                up.append(String.format(Locale.US, "%s %s %.2f / %.0f%%", v == 0 ? " " : ", ", vname[v],
                    psnr(qcMse[r][v], qcUpPx * 3), 100.0 * qcGrad[r][v] / qcRefGrad));
            }
        }
        upQualityText = up.toString();
        for (String line : (fgQualityText + "\n" + upQualityText).split("\n")) {
            if (!line.isEmpty()) Log.i(TAG, "QUALITY " + line);
        }
    }
    /** Frame loop while Frame Gen runs: Dynamic controls the REAL frame rate (half the panel). */
    private int drawFrameGen(int kind, int m, int rung, float animTime, long now, boolean modeChangedThisFrame) {
        boolean timed = false;
        if (kind == FG_REAL) {
            float interval = fgLastRealNanos == 0 ? 0f : (now - fgLastRealNanos) / 1e6f;
            fgLastRealNanos = now;
            if (m == DYNAMIC && !modeChangedThisFrame && !paced) {
                // Uncapped: the interval between real frames IS the cost of a real+generated pair.
                dyn.updateDynamic(interval);
                rung = dyn.rung();
            } else if (m == DYNAMIC && !modeChangedThisFrame) {
                // Probe the real GPU cost of a pair every 60 real frames: vsync hides headroom
                // from the frame interval, so time one real and one generated frame directly.
                if (--fgProbeCountdown <= 0) {
                    fgProbeCountdown = 60;
                    timed = true;
                    fgProbeGenPending = true;
                }
                // The probe times each frame with glFinish, which adds fixed driver latency; the
                // benchmark measured that latency against true throughput, so remove it here.
                float estimate = (fgProbeRealMs > 0f && fgProbeGenMs > 0f)
                    ? Math.max(0.5f, fgProbeRealMs - fgRealBiasMs) + Math.max(0.5f, fgProbeGenMs - fgGenBiasMs)
                    : 0f;
                // A pair that overruns its 2-vsync budget shows up in the interval; otherwise
                // trust the measured pair cost.
                float overrun = 2000f / panelHz * 1.08f;   // two panel intervals per real frame
                float sample = interval > overrun ? interval : (estimate > 0f ? estimate : interval);
                dyn.updateDynamic(sample);
                rung = dyn.rung();
                if (rung != fgLastRung) {
                    fgLastRung = rung;
                    fgProbeRealMs = fgProbeGenMs = 0f;   // measured at the old rung
                }
            }
        } else if (fgProbeGenPending) {
            fgProbeGenPending = false;
            timed = true;
        }
        float ms = fgDrawSlot(kind, m, rung, animTime, timed ? 1 : 0);
        if (timed) {
            if (kind == FG_REAL) {
                fgProbeRealMs = ms;
            } else {
                fgProbeGenMs = ms;
                Log.i(TAG, String.format(Locale.US, "PROBE(FG) real %.1f + generated %.1f ms timed (latency incl.) at %s",
                    fgProbeRealMs, fgProbeGenMs, rungName(rung)));
            }
        }
        return rung;
    }
    // ---------------------------------------------------------------------------------------
    // Off-screen benchmark
    // ---------------------------------------------------------------------------------------

    // The start-up benchmark measures what is really on the screen: each mode is drawn to the
    // display with VSync off for a run of frames, and the frame-to-frame interval is timed.
    // (Off-screen timing is not trustworthy on this class of driver: glFinish adds a fixed
    // latency to every timed frame, and frames rendered back to back can be overlapped or
    // partly skipped.) One ordinary frame per displayed frame, so the screen never freezes.
    private static final int BENCH_START_FRAME = 30;
    private static final int BENCH_WARMUP = 3, BENCH_FRAMES = 12;
    private static final int[] BENCH_MODES = {NATIVE, 1, 2, 3, DYNAMIC, 4, BILINEAR, TEMPORAL};
    private static final int[] BENCH_RUNGS = {MabaController.RUNG_CEIL, 28, 18, 10, 9, 0, 9, 10};
    private static final String[] BENCH_NAMES = {"Native resolution", "Ultra Quality 0.77",
        "Quality 0.67", "Balanced 0.59", "Balanced-lite 0.59 fast", "Performance 0.50",
        "Bilinear 0.59 (no MABA)", "MABA-Upscaler 2 (Temporal) 0.59"};
    private final double[] benchMs = new double[BENCH_MODES.length];
    private final double[] fgBenchPair = new double[BENCH_MODES.length];
    private int benchJob, benchStep, benchCount;
    private double benchAcc, benchT0;
    private boolean benchLastMeasured;
    private float probeBiasMs;       // fixed glFinish latency in a single timed frame (calibrated)

    /** Jobs: 0-1 load calibration, one round over every mode, then - when Frame Gen
     *  is available - every mode that supports it (all but Temporal, the last entry) with real and
     *  generated frames alternating. */
    private static final int FG_BENCH_START = 2 + BENCH_MODES.length;

    private int benchJobCount() {
        return FG_BENCH_START + (fgReady ? BENCH_MODES.length - 1 : 0);
    }

    private boolean benchmarking() {
        return !benchDone && !dumpMode && frame >= BENCH_START_FRAME;
    }

    /**
     * One benchmark frame. dt is the interval since the previous frame started, i.e. the time the
     * previous frame took to render and present; it is credited to that frame's job.
     */
    private void benchFrame(float dt) {
        if (!qcRunning && benchJob < benchJobCount() && devQcFast) {
            // Developer shortcut: skip the benchmark, run only the quality phase.
            Arrays.fill(benchMs, 20.0);
            Arrays.fill(fgBenchPair, 40.0);
            benchJob = benchJobCount();
            startQualityRun();
        }
        if (qcRunning) {
            // Quality checks: show a normal frame, then take one sample off-screen.
            drawMode(3, 10, 0, 20f);
            boolean done = qualityStep();
            benchText = String.format(Locale.US, "checking quality... %d%%", qcStep * 100 / qcSteps());
            fgBenchText = benchText;
            if (done) { qcRunning = false; finishBenchmark(true); }
            return;
        }
        if (benchLastMeasured && dt > 0f) { benchAcc += dt; benchCount++; }
        benchLastMeasured = false;
        if (benchStep >= BENCH_WARMUP + BENCH_FRAMES) {
            finishBenchJob();
            if (benchDone) return;
        }
        int job = benchJob;
        if (job >= FG_BENCH_START) {
            int idx = job - FG_BENCH_START;
            int m = BENCH_MODES[idx], rung = BENCH_RUNGS[idx];
            if (benchStep == 0) {
                fgHavePrev = false;
                fgWriteSlot = 0;
                benchFgTime = 20f;
            }
            // Debug extra fgbench: 0 = alternate (normal), 1 = real frames only, 2 = generated only.
            int pat = devFgBench;
            int kind = pat == 1 ? FG_REAL : (pat == 2 ? (benchStep == 0 ? FG_REAL : FG_GENERATED)
                : ((benchStep & 1) == 0 ? FG_REAL : FG_GENERATED));
            if (kind == FG_REAL) benchFgTime += 1f / 30f;     // like a game at 30 real fps
            fgDrawSlot(kind, m, rung, benchFgTime, 0);
        } else {
            int m, rung;
            if (job < 2) {
                m = BILINEAR;
                rung = 9;
                load = job == 0 ? 0 : 64;
            } else {
                int idx = (job - 2) % BENCH_MODES.length;
                m = BENCH_MODES[idx];
                rung = BENCH_RUNGS[idx];
                if (m == TEMPORAL && progTemporal == 0) {
                    benchMs[idx] = Double.NaN;
                    nextBenchJob();
                    return;
                }
                if (benchStep == 0) {
                    temporal.reset();
                    havePrevVP = false;
                }
            }
            drawMode(m, rung, 0, 20f);
        }
        benchLastMeasured = benchStep >= BENCH_WARMUP;
        benchStep++;
    }

    private void finishBenchJob() {
        int job = benchJob;
        double ms = benchCount > 0 ? benchAcc / benchCount : Double.NaN;
        if (job >= FG_BENCH_START) {
            int idx = job - FG_BENCH_START;
            fgBenchPair[idx] = 2.0 * ms;                    // one real + one generated frame
            if (devFgBench != 0) {
                Log.i(TAG, String.format(Locale.US, "FGBENCH pattern %d %s: %.2f ms per frame (normal frame %.2f)",
                    devFgBench, BENCH_NAMES[idx], ms, benchMs[idx]));
            }
        } else if (job == 0) {
            benchT0 = ms;
        } else if (job == 1) {
            double perUnit = Math.max(1e-4, (ms - benchT0) / 64.0);
            load = (int) Math.max(0, Math.min(4000, Math.round((CALIBRATION_MS - benchT0) / perUnit * loadMul)));
            Log.i(TAG, String.format(Locale.US, "calibration: load=%d (loadmul %.2f)", load, loadMul));
        } else {
            int idx = (job - 2) % BENCH_MODES.length;
            if (job - 2 < BENCH_MODES.length || ms < benchMs[idx]) benchMs[idx] = ms;
        }
        nextBenchJob();
    }

    private String buildFgBenchText() {
        if (!fgReady) return "MABA Frame Gen is not supported on this GPU (needs float render targets).";
        StringBuilder sb = new StringBuilder(String.format(Locale.US,
            "MABA Frame Gen ON - measured on screen, VSync off, scene load %d. shown = real + generated:", load));
        for (int i = 0; i < BENCH_MODES.length; i++) {
            if (Double.isNaN(benchMs[i])) continue;
            String line;
            if (i == BENCH_MODES.length - 1) {              // Temporal has no frame gen
                line = String.format(Locale.US, "%s: %.1f fps (no frame gen in this mode)",
                    BENCH_NAMES[i], 1000.0 / benchMs[i]);
            } else {
                double pair = fgBenchPair[i];
                line = String.format(Locale.US,
                    "%s: real %.1f -> shown %.1f fps (%+.0f%% vs without; pair %.1f ms, a frame without Frame Gen %.1f ms)",
                    BENCH_NAMES[i], 1000.0 / pair, 2000.0 / pair,
                    (2.0 * benchMs[i] / pair - 1.0) * 100.0, pair, benchMs[i]);
            }
            Log.i(TAG, "FRAMEGEN " + line);
            sb.append("\n  ").append(line);
        }
        if (!fgQualityText.isEmpty()) sb.append("\n").append(fgQualityText);
        return sb.toString();
    }

    private void nextBenchJob() {
        benchJob++;
        benchStep = 0;
        benchAcc = 0;
        benchCount = 0;
        benchLastMeasured = false;
        benchText = String.format(Locale.US, "benchmarking on screen, VSync off... %d%%", benchJob * 100 / benchJobCount());
        fgBenchText = benchText;
        if (benchJob < benchJobCount()) return;

        calibrateProbe();
        StringBuilder sb = new StringBuilder(
            String.format(Locale.US, "Measured on screen, VSync off, scene load %d:", load));
        for (int i = 0; i < BENCH_MODES.length; i++) {
            if (Double.isNaN(benchMs[i])) continue;
            String line = String.format(Locale.US, "%s: %.1f fps (%.1f ms, %+.0f%% vs native)",
                BENCH_NAMES[i], 1000.0 / benchMs[i], benchMs[i], (benchMs[0] / benchMs[i] - 1.0) * 100.0);
            Log.i(TAG, "FRAME " + line);
            sb.append("\n  ").append(line);
        }
        benchText = sb.toString();
        benchBaseText = benchText;
        if (getIntent().getIntExtra("qcstart", 0) == 1) {
            startQualityRun();      // quality checks next, one small sub-step per frame
        } else {
            finishBenchmark(false); // start-up ends here: no stutter phase
        }
    }

    /**
     * One-off calibration of the live Dynamic probe. A frame timed on its own with glFinish
     * includes fixed driver latency that a frame in a running loop does not; the difference to the
     * on-screen interval measured above (Balanced) is that latency.
     */
    private void calibrateProbe() {
        int idx = 3;                                    // Balanced 0.59
        if (Double.isNaN(benchMs[idx])) return;
        drawMode(BENCH_MODES[idx], BENCH_RUNGS[idx], outFbo, 20f);
        double sum = 0;
        for (int i = 0; i < 3; i++) {
            GLES30.glFinish();
            long t0 = System.nanoTime();
            drawMode(BENCH_MODES[idx], BENCH_RUNGS[idx], outFbo, 20f);
            GLES30.glFinish();
            sum += (System.nanoTime() - t0) / 1e6;
        }
        probeBiasMs = (float) Math.max(0.0, sum / 3.0 - benchMs[idx]);
        Log.i(TAG, String.format(Locale.US, "probe calibration: +%.1f ms fixed latency per timed frame", probeBiasMs));
        if (fgReady && fgBenchPair[idx] > 0) {
            fgHavePrev = false;
            fgWriteSlot = 0;
            float r = 0, g = 0;
            for (int i = 0; i < 3; i++) {
                r = fgDrawSlot(FG_REAL, BENCH_MODES[idx], BENCH_RUNGS[idx], 20f + i / 30f, 2);
                g = fgDrawSlot(FG_GENERATED, BENCH_MODES[idx], BENCH_RUNGS[idx], 20f + i / 30f, 2);
            }
            float half = (float) Math.max(0.0, (r + g - fgBenchPair[idx]) / 2.0);
            fgRealBiasMs = half;
            fgGenBiasMs = half;
            Log.i(TAG, String.format(Locale.US, "FG probe calibration: +%.1f ms fixed latency per timed frame", half));
        }
    }

    private void finishBenchmark(boolean ranQuality) {
        if (ranQuality) finishQualityChecks();
        benchText = benchBaseText + "\n" + (upQualityText.isEmpty()
            ? "Image quality: not measured this run (hold the screen, then \"Run image-quality check\")"
            : upQualityText);
        fgBenchText = buildFgBenchText();
        temporal.reset();
        havePrevVP = false;
        fgHavePrev = false;
        fgWriteSlot = 0;
        benchDone = true;
        modeChanged = true;
        labelDirty = true;
    }
    // ---------------------------------------------------------------------------------------
    // Dump mode: reference pattern -> PPM for host comparison against the CPU golden reference
    // ---------------------------------------------------------------------------------------

    private void runDump() {
        int rw = Math.max(2, Math.round(outW * MabaController.rungScale(dumpRung)));
        int rh = Math.max(2, Math.round(outH * MabaController.rungScale(dumpRung)));
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, sceneFbo[0]);
        GLES30.glViewport(0, 0, rw, rh);
        GLES30.glDisable(GLES30.GL_DEPTH_TEST);
        GLES30.glUseProgram(progPattern);
        GLES30.glUniform1i(uloc(progPattern, "uPattern"), dumpPattern);
        GLES30.glUniform2f(uloc(progPattern, "uRes"), rw, rh);
        GLES30.glBindVertexArray(vao[0]);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
        int prog = dumpQuality != 0 ? progQuality : progFast;
        upscale(sceneTex, prog, 0, rw, rh);
        GLES30.glFinish();

        ByteBuffer buf = ByteBuffer.allocateDirect(outW * outH * 4);
        GLES30.glReadPixels(0, 0, outW, outH, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf);
        File f = new File(getExternalFilesDir(null), "dump.ppm");
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(("P6\n" + outW + " " + outH + "\n255\n").getBytes("UTF-8"));
            byte[] row = new byte[outW * 3];
            for (int y = outH - 1; y >= 0; y--) {   // GL readback is bottom-up
                for (int x = 0; x < outW; x++) {
                    int i = (y * outW + x) * 4;
                    row[x * 3] = buf.get(i);
                    row[x * 3 + 1] = buf.get(i + 1);
                    row[x * 3 + 2] = buf.get(i + 2);
                }
                out.write(row);
            }
            Log.i(TAG, "DUMP " + f.getAbsolutePath() + " pattern=" + dumpPattern
                + " rung=" + dumpRung + " quality=" + dumpQuality);
        } catch (Exception e) {
            Log.e(TAG, "dump failed", e);
        }
        runOnUiThread(new Runnable() { @Override public void run() { finish(); } });
    }

    // ---------------------------------------------------------------------------------------
    // Frame loop
    // ---------------------------------------------------------------------------------------

    @Override
    public void onDrawFrame(GL10 unused) {
        GLES30.glBindVertexArray(vao[0]);
        frame++;
        paced = vsyncWanted;
        int wantVsync = (paced && !benchmarking()) ? 1 : 0;   // the benchmark always runs uncapped
        // Swap interval 0 = present without waiting for the panel's refresh (uncapped). A request
        // that succeeds is not always honoured: measured on the test phone, about one launch in
        // four stayed locked to the panel (Frame Gen 30 real + 30 generated = 60 fps) although
        // eglSwapInterval(0) had returned success on the first frame, and never recovered; with
        // the request repeated, 0 of 16 launches stayed locked. So the interval is asserted again
        // on a back-off schedule (frames 3, 7, 15, 31, ... then every 240 frames), which costs one
        // trivial EGL call, and after every change of the setting or of the surface.
        if (wantVsync != appliedVsync || (!devNoReassert && frame >= swapNextFrame)) {
            boolean changed = wantVsync != appliedVsync;
            boolean ok = EGL14.eglSwapInterval(EGL14.eglGetCurrentDisplay(), wantVsync);
            appliedVsync = wantVsync;
            if (changed) {
                Log.i(TAG, "VSync " + (wantVsync == 1 ? "ON" : "OFF (uncapped)") + (ok ? "" : " - driver refused"));
                targetChanged = true;
                labelDirty = true;
                swapGap = 2;
            } else if (!ok) {
                Log.w(TAG, "VSync " + (wantVsync == 1 ? "ON" : "OFF") + " could not be re-applied - driver refused");
            }
            swapNextFrame = frame + swapGap;
            swapGap = Math.min(swapGap * 2, SWAP_REASSERT_MAX);
        }
        if (dumpMode) {
            if (frame == 2) runDump();
            return;
        }
        if (qcRequested && benchDone) {
            // On demand: re-enter the benchmark state machine in its quality-only phase.
            qcRequested = false;
            benchDone = false;
            benchJob = benchJobCount();
            startQualityRun();
        }
        long now = System.nanoTime();
        if (lastNanos != 0 && (now - lastNanos) > 45_000_000L) {
            // A hitch: a frame that took over 45 ms to arrive. Says what the app was doing.
            Log.w(TAG, String.format(Locale.US, "HITCH %.0f ms at frame %d (%s)", (now - lastNanos) / 1e6, frame,
                benchmarking() ? "benchmark job " + benchJob + " step " + benchStep : benchDone ? "running" : "waiting to benchmark"));
        }
        if (benchmarking()) {
            float dt = lastNanos == 0 ? 0f : (now - lastNanos) / 1e6f;
            lastNanos = now;
            benchFrame(dt);
            if (fgNative != 0 && MabaNative.fgPresented(fgNative, FG_REAL, now / 1e6) == 1) {
                fgStatsValid = MabaNative.fgStats(fgNative, fgStats) == 1;
                labelDirty = true;
            }
            if (labelDirty) { labelDirty = false; postLabel(mode, dyn.rung()); }
            return;
        }
        int m = mode;
        if (m == TEMPORAL && progTemporal == 0) m = DYNAMIC;

        // Is MABA Frame Gen running this frame? If it was asked for but cannot run, say why.
        boolean fgOn = false;
        String note = "";
        if (fgWanted) {
            if (fgNative == 0) note = "needs the native library";
            else if (!fgReady) note = "this GPU cannot render to float targets";
            else if (!benchDone) note = "starts when the benchmark finishes";
            else if (m == TEMPORAL && !u3Only) note = "not available in this mode - tap to change mode";
            else if (u3Only && (progFgWarpHi == 0 || !tsrActive())) note = "Frame Gen needs the temporal pass (float targets)";
            else fgOn = true;
        }
        if (!note.equals(fgNote)) { fgNote = note; labelDirty = true; }
        if (fgOn != fgActive || (fgOn && fgFactor != fgFactorApplied)) {
            fgActive = fgOn;
            fgFactorApplied = fgFactor;
            if (fgNative != 0) {
                MabaNative.fgSetEnabled(fgNative, fgOn ? 1 : 0);   // also restarts the counters
                MabaNative.fgSetGenPerReal(fgNative, fgFactorApplied - 1);
                if (fgOn) MabaNative.fgSetEnabled(fgNative, 1);
            }
            fgHavePrev = false;
            fgLastRealNanos = 0;
            fgStatsValid = false;
            fgProbeRealMs = fgProbeGenMs = 0f;
            fgProbeCountdown = 60;
            fgLastRung = NO_RUNG;
            targetChanged = true;
            labelDirty = true;
            govReset = true;
            leanHave = false;
        }

        // 0 on the first frame after (re)start: the controller ignores non-positive samples.
        float frameMs = lastNanos == 0 ? 0f : (now - lastNanos) / 1e6f;
        lastNanos = now;
        if (rangeChanged) {         // resets the controller's counters: only on a real change
            rangeChanged = false;
            applyScaleRange();
        }
        if (targetChanged) {
            targetChanged = false;
            dyn.setTargetFps(controllerTargetFps());
        }
        boolean modeChangedThisFrame = modeChanged;
        if (modeChanged) {
            modeChanged = false;
            dyn.setMode(MabaController.MODE_DYNAMIC);
            dyn.setTargetFps(controllerTargetFps());
            if (benchDone) {   // while benchmarking, the temporal history belongs to the benchmark
                temporal.reset();
                havePrevVP = false;
                lastRung = NO_RUNG;
            }
            fgHavePrev = false;
            fgLastRealNanos = 0;
            fgProbeRealMs = fgProbeGenMs = 0f;
            fgProbeCountdown = 60;
            fgLastRung = NO_RUNG;
            if (fgNative != 0) MabaNative.fgInvalidate(fgNative);
            probeMs = 0;
            probeCountdown = 60;
            labelDirty = true;
        }
        int rung = (m == DYNAMIC || m == TEMPORAL) ? dyn.rung() : MODE_RUNG[m];
        // The governor keeps Frame Gen on only while it shows more frames per second than leaving it off.
        restartGovernor();
        boolean fgRun = fgOn && (!fgGovEnabled || fgGov == 0 || fgGovOn);
        int slotKind = (fgRun && fgNative != 0) ? MabaNative.fgNextSlot(fgNative) : FG_REAL;
        if (fgDbg == 2) slotKind = FG_REAL;
        if (fgOn && fgGovEnabled && fgGov != 0 && slotKind == FG_REAL) {
            float interval = govLastRealNanos == 0 ? 0f : (now - govLastRealNanos) / 1e6f;
            govLastRealNanos = now;
            boolean want = MabaNative.govStep(fgGov, interval) == 1;
            MabaNative.govInfo(fgGov, fgGovInfo);
            if (want != fgGovOn) {
                fgGovOn = want;
                fgRun = want;
                slotKind = FG_REAL;
                if (fgNative != 0) MabaNative.fgInvalidate(fgNative);
                leanHave = false;
                labelDirty = true;
            }
        }
        float animTime = anim ? (now - startNanos) / 1e9f : 20f;

        if (slotKind == FG_REAL) camUpdate(animTime);   // the camera reads the touch input once per REAL frame, as a game would
        if (latMode) latBeforeDraw(now, slotKind);
        fgShownKind = slotKind;
        if (fgRun) {
            rung = u3Only ? drawLeanFrameGen(slotKind, animTime) : drawFrameGen(slotKind, m, rung, animTime, now, modeChangedThisFrame);
        } else {
            rung = drawNormal(m, rung, animTime, frameMs, modeChangedThisFrame);
        }

        if (latMode && latOk) latAfterDraw(fgRun ? fgShownKind : FG_REAL);

        // Honest counters: every frame handed to the platform is counted once, per kind, and the
        // numbers are only published when a full one-second window has completed.
        boolean fgRolled = fgNative != 0 && MabaNative.fgPresented(fgNative, slotKind, now / 1e6) == 1;
        if (fgRolled) {
            fgStatsValid = MabaNative.fgStats(fgNative, fgStats) == 1;
            Log.i(TAG, String.format(Locale.US, "ONSCREEN %s%s = real %.1f + generated %.1f = shown %.1f fps%s (%s)",
                modeName(m), (m == DYNAMIC || m == TEMPORAL) ? " [" + rungName(rung) + "]" : "",
                fgStats[0], fgStats[1], fgStats[2], fgOn ? " [MABA Frame Gen]" : "", gpuText()));
            labelDirty = true;
        }
        if (labelDirty) {
            labelDirty = false;
            postLabel(m, rung);
        }
    }

    private static float span(MotionEvent ev) {
        final float dx = ev.getX(0) - ev.getX(1), dy = ev.getY(0) - ev.getY(1);
        return (float) Math.sqrt(dx * dx + dy * dy);
    }

    /** UI thread: one finger orbits, two fingers pinch. Only accumulates; the render thread applies it once per real frame. */
    private void handleCameraTouch(MotionEvent ev) {
        switch (ev.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                touchX = ev.getX(); touchY = ev.getY(); touchSpan = 0f;
                break;
            case MotionEvent.ACTION_POINTER_DOWN:
                if (ev.getPointerCount() == 2) touchSpan = span(ev);
                break;
            case MotionEvent.ACTION_POINTER_UP: {
                // One finger stays: continue the orbit from it without a jump.
                final int keep = ev.getActionIndex() == 0 ? 1 : 0;
                if (ev.getPointerCount() > keep) { touchX = ev.getX(keep); touchY = ev.getY(keep); }
                touchSpan = 0f;
                break;
            }
            case MotionEvent.ACTION_MOVE:
                synchronized (camLock) {
                    if (ev.getPointerCount() == 1) {
                        final float dx = ev.getX() - touchX, dy = ev.getY() - touchY;
                        if (!camUser && !camInitPending && dx * dx + dy * dy < 36f) break;   // a tap, not a drag
                        if (!camUser) camInitPending = true;
                        camDYaw -= dx * 0.0055f;
                        camDPitch += dy * 0.0040f;
                        touchX = ev.getX(); touchY = ev.getY();
                    } else if (ev.getPointerCount() >= 2) {
                        final float s = span(ev);
                        if (touchSpan > 1f && s > 1f) {
                            if (!camUser) camInitPending = true;
                            camDZoom *= touchSpan / s;
                        }
                        touchSpan = s;
                        touchX = (ev.getX(0) + ev.getX(1)) * 0.5f; touchY = (ev.getY(0) + ev.getY(1)) * 0.5f;
                    }
                }
                break;
            default:
                break;
        }
    }

    /** Render thread, once per real frame: applies the accumulated touch input to the camera. */
    private void camUpdate(float animTime) {
        synchronized (camLock) {
            if (camInitPending && !camUser) {
                // Take over from wherever the auto camera is now, so the first drag does not jump.
                final float[] e = autoEye(animTime);
                final float h = (float) Math.sqrt(e[0] * e[0] + e[2] * e[2]);
                camYaw = (float) Math.atan2(e[0], e[2]);
                camPitch = (float) Math.atan2(e[1] - CAM_TARGET_Y, h);
                camDist = (float) Math.sqrt(h * h + (e[1] - CAM_TARGET_Y) * (e[1] - CAM_TARGET_Y));
                camUser = true;
            }
            camInitPending = false;
            if (camUser) {
                camYaw += camDYaw;
                camPitch = Math.max(-0.05f, Math.min(1.25f, camPitch + camDPitch));
                camDist = Math.max(2.4f, Math.min(6.0f, camDist * camDZoom));
            }
            camDYaw = 0f; camDPitch = 0f; camDZoom = 1f;
        }
    }

    private void latBeforeDraw(long now, int slotKind) {
        if (frame == 3 && !latOk) {
            latOk = MabaNative.latEnable() == 1;
            Log.i(TAG, "LAT frame timestamps " + (latOk ? "enabled" : "UNAVAILABLE on this device"));
        }
        final long touch = latTouchNs;
        if (touch != 0 && touch <= now && slotKind == FG_REAL && latPending < LAT_MAX) {
            latTouchNs = 0;
            latSIdx[latPending] = latCount;
            latSTouch[latPending] = touch;
            latSStart[latPending] = now;
            latPending++;
        }
    }

    private void latAfterDraw(int shown) {
        // The next eglSwapBuffers (right after this method returns) gets this id.
        final int i = latCount % LAT_RING;
        latFrameId[i] = MabaNative.latNextFrameId();
        latShown[i] = shown;
        latCount++;
        // The platform keeps timestamps for only the last 8 frames, and the display-present time of a frame is known a
        // few frames after it: try from 4 swaps after the sample until 7, then give up on that tap.
        for (int k = 0; k < latPending; ) {
            final int age = latCount - latSIdx[k];
            if (age < 4 || !latResolve(k, age >= 7)) {
                if (age < 7) { k++; continue; }
            }
            for (int j = k; j < latPending - 1; j++) { latSIdx[j] = latSIdx[j + 1]; latSTouch[j] = latSTouch[j + 1]; latSStart[j] = latSStart[j + 1]; }
            latPending--;
        }
    }

    /** Logs one tap: touch -> sampled, and sampled -> glass for the first frame that carries the new real frame. */
    private boolean latResolve(int k, boolean last) {
        final int s = latSIdx[k];
        int r = s;                                           // first swap at or after the sample that shows a REAL frame
        while (r < s + 8 && latShown[r % LAT_RING] != FG_REAL) r++;
        final boolean a = MabaNative.latQuery(latFrameId[s % LAT_RING], latTsA) == 1;
        final boolean b = MabaNative.latQuery(latFrameId[r % LAT_RING], latTsB) == 1;
        if (!a || !b) {
            if (last) Log.w(TAG, "LAT sample dropped: the platform had no display-present time for it");
            return false;
        }
        final long touch = latSTouch[k], start = latSStart[k];
        Log.i(TAG, String.format(Locale.US,
            "LAT touch_to_sample=%.2f first_visible_present=%.2f real_present=%.2f first_visible_total=%.2f real_total=%.2f gpu_done_to_present=%.2f shown_at_sample=%d",
            (start - touch) / 1e6, (latTsA[3] - start) / 1e6, (latTsB[3] - start) / 1e6,
            (latTsA[3] - touch) / 1e6, (latTsB[3] - touch) / 1e6, latTsB[1] > 0 ? (latTsB[3] - latTsB[1]) / 1e6 : -1.0, latShown[s % LAT_RING]));
        return true;
    }

    /** The ordinary frame (Frame Gen off): controller update, optional probe, draw. */
    private int drawNormal(int m, int rung, float animTime, float frameMs, boolean modeChangedThisFrame) {
        if (u3Only) { rung = presetRung(); pollReset(); }
        boolean probeNow = false;
        if (!u3Only && !modeChangedThisFrame && (m == DYNAMIC || m == TEMPORAL) && benchDone) {
            float sample;
            // Some Mali drivers latch timestamps at frame granularity, so the query just echoes
            // the present-to-present interval. Trust it only when it shows headroom that
            // present-to-present cannot see.
            boolean timerTrusted = gpuTimer.usable() && gpuTimer.gpuMs < frameMs - 1.0f;
            if (!paced) {
                // Uncapped: nothing waits for the panel, so the frame interval IS the frame cost.
                sample = frameMs;
            } else if (timerTrusted) {
                sample = gpuTimer.gpuMs;                 // real per-frame GPU timing
            } else {
                // Every 120 frames, time THIS frame's real work with glFinish (no extra frames
                // are drawn, so there is no visible hitch). Between probes a real overrun is
                // visible present-to-present; otherwise hold the last probe estimate.
                if (--probeCountdown <= 0) {
                    probeCountdown = 120;
                    probeNow = true;
                }
                // An overrun of the panel interval is visible present-to-present.
                float overrun = 1000f / panelHz * 1.08f;
                sample = frameMs > overrun ? frameMs : (probeMs > 0 ? probeMs : frameMs);
            }
            dyn.updateDynamic(sample);
            rung = dyn.rung();
        }

        // While the benchmark is still running it owns the temporal history, so show the
        // spatial path in the meantime.
        int drawM = m, drawRung = rung;
        if (!benchDone && m == TEMPORAL) { drawM = 3; drawRung = 10; }

        gpuTimer.begin();
        if (probeNow) {
            // Time this frame's real work on the off-screen target: drawing into the window
            // would also time Android's wait for a free swap buffer (one vsync), hiding all GPU
            // headroom. Then copy the finished frame to the window, so it is still shown and
            // nothing is drawn twice.
            GLES30.glFinish();
            long probeStart = System.nanoTime();
            drawMode(drawM, drawRung, outFbo, animTime);
            GLES30.glFinish();
            // Remove the fixed glFinish latency measured by the benchmark: the probe estimates cost.
            probeMs = Math.max(0.5f, (System.nanoTime() - probeStart) / 1e6f - probeBiasMs);
            blitOutToWindow();
            Log.i(TAG, String.format(Locale.US, "PROBE gpu %.1f ms at %s", probeMs, rungName(rung)));
        } else {
            drawMode(drawM, drawRung, 0, animTime);
        }
        gpuTimer.end();
        return rung;
    }

    /** Overlay text. Built on the GL thread, shown on the UI thread; refreshed once per second. */
    private void postLabel(int m, int rung) {
        if (u3Only) { postLabel(rung); return; }
        String fpsText;
        if (!fgStatsValid) {
            fpsText = "-- fps";
        } else if (fgActive && !paced && fgStats[2] > panelHz + 1f) {
            // Uncapped Frame Gen faster than the panel: every frame is presented, not every one shown.
            fpsText = String.format(Locale.US, "REAL %.0f + GENERATED %.0f = OUTPUT %.0f fps (panel shows %.0f)",
                fgStats[0], fgStats[1], fgStats[2], panelHz);
        } else if (fgActive) {
            fpsText = String.format(Locale.US, "REAL %.0f + GENERATED %.0f = SHOWN %.0f fps",
                fgStats[0], fgStats[1], fgStats[2]);
        } else if (!paced && fgStats[2] > panelHz + 1f) {
            // Uncapped and faster than the panel: say how many can actually be displayed.
            fpsText = String.format(Locale.US, "%.0f fps rendered, panel shows %.0f", fgStats[2], panelHz);
        } else {
            fpsText = String.format(Locale.US, "%.0f fps", fgStats[2]);
        }
        StringBuilder sb = new StringBuilder();
        sb.append(modeName(m));
        if (m == DYNAMIC || m == TEMPORAL) sb.append("  ->  ").append(rungName(rung));
        sb.append("   |   ").append(fpsText)
          .append("   |   ").append(gpuText())
          .append(String.format(Locale.US, "   |   VSync %s   |   thermal %d   |   panel %.0f Hz   |   tap: mode, hold: settings",
              vsyncWanted ? "on" : "OFF", thermalStatus, panelHz));
        if (!paced && fgStatsValid && fgStats[2] > panelHz + 1f) {
            sb.append(String.format(Locale.US, "\nUncapped: %.0f frames per second are rendered and presented, but this %.0f Hz panel"
                + " can only display %.0f of them per second", fgStats[2], panelHz, panelHz));
        }
        if (fgActive) {
            sb.append("\nMABA Frame Gen ON: every frame is counted when it is presented; generated frames are"
                + " predicted from the last real frame, not rendered");
        } else if (fgWanted) {
            sb.append("\nMABA Frame Gen requested - ").append(fgNote);
        }
        sb.append('\n').append(fgActive ? fgBenchText : benchText).append('\n').append(glInfo);
        final String text = sb.toString();
        final String vsyncText = vsyncWanted ? "VSync: ON (capped to the panel)" : "VSync: OFF (uncapped)";
        runOnUiThread(new Runnable() {
            @Override public void run() {
                label.setText(text);
                vsyncBtn.setText(vsyncText);
            }
        });
    }

    /** GPU time for the overlay: the timer query if it really measures, else the probe. */
    private String gpuText() {
        if (fgActive && fgProbeRealMs > 0f && fgProbeGenMs > 0f) {
            return String.format(Locale.US, "gpu ~%.1f ms per real+generated pair (probe)",
                Math.max(0.5f, fgProbeRealMs - fgRealBiasMs) + Math.max(0.5f, fgProbeGenMs - fgGenBiasMs));
        }
        if (gpuTimer.usable()) return String.format(Locale.US, "gpu %.1f ms", gpuTimer.gpuMs);
        if (probeMs > 0) return String.format(Locale.US, "gpu ~%.1f ms (probe)", probeMs);
        return "gpu n/a";
    }

    private static String rungName(int rung) {
        if (MabaController.rungNative(rung)) return "native";
        return String.format(Locale.US, "%.2f %s", MabaController.rungScale(rung),
            MabaController.rungQuality(rung) ? "quality" : "fast");
    }
}
