// MABA Upscaler - camera component. Renders the camera into a sub-region of a fixed-size
// render texture (no reallocation on scale changes) and upscales that region to the screen
// after the camera has finished, before screen-space overlay UI. By default it runs MABA
// Upscaler 3's temporal super-resolution (jittered render, accumulation at output resolution); where
// that is unavailable it falls back to the single-pass spatial upscale.
//
// Works with URP and the built-in pipeline: the camera renders normally into targetTexture
// (post-processing/tonemapping included), so the upscaler input is finished LDR color.
// Built-in calls OnPostRender; scriptable pipelines call RenderPipelineManager.endCameraRendering.
//
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maba3
{
    [RequireComponent(typeof(Camera))]
    [DisallowMultipleComponent]
    [AddComponentMenu("MABA/MABA Upscaler 3")]
    public sealed class MabaUpscaler : MonoBehaviour
    {
        // Order matches MabaController.Mode* and the C header's MabaMode.
        public enum Mode { Dynamic, UltraQuality, Quality, Balanced, Performance }

        [Header("Upscaler")]
        [Tooltip("Dynamic holds the target frame rate by moving render scale in 1% steps. The others are fixed render scales: Ultra Quality 0.77, Quality 0.67, Balanced 0.59, Performance 0.50.")]
        public Mode mode = Mode.Dynamic;
        [Tooltip("Sharpening strength. 0.5 is the measured sweet spot.")]
        [Range(0f, 1f)] public float sharpness = 0.5f;
        [Header("Dynamic mode")]
        [Tooltip("The frame rate Dynamic mode holds.")]
        public float targetFps = 60f;
        [Tooltip("Dynamic mode never renders below this fraction of the screen resolution (0.35..1). The fixed presets ignore the range.")]
        [Range(0.35f, 1f)] public float minScale = 0.35f;
        [Tooltip("Dynamic mode never renders above this fraction of the screen resolution (0.35..1; 1 = native, no upscale pass). A lower ceiling also allocates a smaller render texture.")]
        [Range(0.35f, 1f)] public float maxScale = 1f;
        [Tooltip("Temporal super-resolution: jittered render, accumulation at output resolution. Needs the depth texture. Off = the single-pass spatial upscale.")]
        public bool temporal = true;
        [Header("Temporal tuning (only used when Temporal is on)")]
        [Tooltip("Width of the colour clamp that rejects ghosts, 1.0 - 1.5. Lower rejects ghosts harder.")]
        [Range(0.5f, 3f)] public float clipGamma = 1.25f;
        [Tooltip("Depth difference that rejects history (disocclusion), 0.005 - 0.02.")]
        [Range(0.001f, 0.1f)] public float depthTolerance = 0.01f;
        [Header("Frame Generation")]
        [Tooltip("Shows extra frames between the rendered ones: 2x renders the scene every second frame, 3x every third. The game keeps updating every frame; the other frames re-project the last rendered one to the camera's current pose. Camera motion is handled; objects that move by themselves update on rendered frames only. Needs Temporal on, a perspective camera and Screen Space - Overlay UI (a camera-space canvas would be skipped on generated frames).")]
        public FrameGeneration frameGeneration = FrameGeneration.Off;
        [Tooltip("Pause Frame Generation while it would not show more frames per second than leaving it off.")]
        public bool frameGenerationAutoPause = true;
        [Header("Settings")]
        [Tooltip("Apply the player's saved choices (MabaSettings.Save) when this component starts.")]
        public bool useSavedSettings = true;
        [Header("Debug")]
        [Tooltip("Show a one-line diagnostic overlay (development only).")]
        public bool debugOverlay = false;

        static readonly int InputId = Shader.PropertyToID("_MabaInput");
        static readonly int InputSizeId = Shader.PropertyToID("_MabaInputSize");
        static readonly int ParamsId = Shader.PropertyToID("_MabaParams");
        static readonly int HistoryId = Shader.PropertyToID("_History");
        static readonly int DepthId = Shader.PropertyToID("_Depth");
        static readonly int PrevDepthId = Shader.PropertyToID("_PrevDepth");
        static readonly int InvVPId = Shader.PropertyToID("_InvVP");
        static readonly int PrevVPId = Shader.PropertyToID("_PrevVP");
        static readonly int TParamsId = Shader.PropertyToID("_TParams");
        static readonly int OutInfoId = Shader.PropertyToID("_OutInfo");
        static readonly int ShownId = Shader.PropertyToID("_MabaShown");
        static readonly int DepthRangeId = Shader.PropertyToID("_DepthRange");
        static readonly int RegionId = Shader.PropertyToID("_Region");
        static readonly int JitterId = Shader.PropertyToID("_Jitter");
        static readonly int ReversedZId = Shader.PropertyToID("_MabaReversedZ");
        static readonly int OutDepthId = Shader.PropertyToID("_MabaOutDepth");
        static readonly int LastVPId = Shader.PropertyToID("_LastVP");
        static readonly int LastInvVPId = Shader.PropertyToID("_LastInvVP");
        static readonly int NewVPId = Shader.PropertyToID("_NewVP");
        static readonly int NewInvVPId = Shader.PropertyToID("_NewInvVP");

        Camera cam;
        MabaController ctrl;
        MabaTemporal jitter;
        RenderTexture sceneRT;
        readonly RenderTexture[] histRT = new RenderTexture[2];    // accumulated history, OUTPUT resolution
        readonly RenderTexture[] outDepthRT = new RenderTexture[2]; // last frame's depth, OUTPUT resolution
        RenderTexture shownRT;                                       // the image to show, OUTPUT resolution (carries the depth buffer the MRT needs)
        RenderTexture depthCurRT;                                    // this frame's depth in GL window depth, render region
        Material upscaleMat, temporalMat, presentMat, copyMat, fgMat;
        // Frame Generation
        GameObject presentGo;                      // hidden child camera that presents generated frames (the main camera is off then)
        Camera presentCam;
        int fgPhase;                               // 0 = this frame renders the scene (real), > 0 = generated
        bool fgGenerating, fgHaveReal;
        int govState;                              // 0 measuring with FG on, 1 probing with FG off, 2 paused
        int govSamples;
        float govSum, govOnMs, govOffMs, govTimer = GovPeriodS;
        const int GovProbeFrames = 14;
        const float GovPeriodS = 12f, GovPauseS = 20f, GovMargin = 0.92f;   // FG must cut ms per displayed frame below 92% of a real frame
        bool gather;                 // false on ES 3.0-class hardware: single gather-free pass
        Rect savedRect;
        DepthTextureMode savedDepthMode;
        bool savedRequiresDepth, haveSavedRequiresDepth;
        float appliedTargetFps;
        float appliedMinScale = -1f, appliedMaxScale = -1f;
        int texW, texH;              // allocated size of the scene texture (largest rung)
        int outRtW, outRtH;          // allocated size of the output-resolution temporal targets
        int rw, rh;                  // this frame's render region
        int lastRw, lastRh;
        int slot;
        bool temporalActive, lastTemporal, projectionOverridden;
        bool nativeFrame;            // scale 1.00 without temporal: the camera renders straight to the screen
        Matrix4x4 plainProj, prevVP;
        Vector2 jitterTexels;        // this frame's jitter, for the resolve pass
        bool havePrevVP;
        readonly FrameTiming[] timings = new FrameTiming[1];
        float gpuMs;
        float fps;
        int fpsFrames;
        double fpsTime;

        static Material NewMaterial(string resource, string shaderName)
        {
            // The shaders live in a Resources folder so player builds include them; Shader.Find
            // alone returns null in a build for a shader nothing else references.
            Shader s = Resources.Load<Shader>(resource);
            if (s == null) s = Shader.Find(shaderName);
            if (s == null || !s.isSupported) return null;
            return new Material(s) { hideFlags = HideFlags.HideAndDontSave };
        }

        // ---- Read-only status (for UI, the inspector and your own code) ----------------------------

        /// <summary>Raised when the render scale changes (Dynamic mode stepping, or a mode change).</summary>
        public event Action<float> ScaleChanged;
        float lastScale = -1f;

        /// <summary>Current render scale, 0.35 .. 1.00 (1.00 = native: nothing is upscaled).</summary>
        public float RenderScale { get { return ctrl != null ? ctrl.Scale : 1f; } }
        /// <summary>Position on the 1% ladder, -15 .. 51.</summary>
        public int Rung { get { return ctrl != null ? ctrl.Rung : 0; } }
        /// <summary>This frame's render region in pixels.</summary>
        public Vector2Int RenderSize { get { return new Vector2Int(rw, rh); } }
        /// <summary>True while the camera renders straight to the screen (scale 1.00, no temporal).</summary>
        public bool IsNative { get { return nativeFrame; } }
        /// <summary>True when the 12-tap quality kernel is in use (false: the fast kernel).</summary>
        public bool QualityKernel { get { return gather && ctrl != null && ctrl.QualityShader && !nativeFrame; } }
        /// <summary>True when the temporal resolve ran this frame.</summary>
        public bool TemporalRunning { get { return temporalActive && histRT[0] != null && !nativeFrame; } }
        /// <summary>Smoothed frames per second (as measured by the component).</summary>
        public float CurrentFps { get { return fps; } }
        /// <summary>GPU time of the last frame in ms where the platform reports it, else 0.</summary>
        public float GpuMs { get { return gpuMs; } }

        /// <summary>Choose Dynamic or one of the fixed presets.</summary>
        public void SetMode(Mode newMode) { mode = newMode; }

        void OnValidate()
        {
            if (maxScale < minScale) maxScale = minScale;
            targetFps = Mathf.Clamp(targetFps, 15f, 240f);
        }

        void OnEnable()
        {
            cam = GetComponent<Camera>();
            if (useSavedSettings)
            {
                MabaUserSettings saved;
                if (MabaSettings.TryLoad(out saved)) ApplyFields(saved);
            }
            ctrl = new MabaController((int)mode, targetFps);
            appliedTargetFps = targetFps;
            ctrl.SetScaleRange(minScale, maxScale);
            appliedMinScale = minScale;
            appliedMaxScale = maxScale;
            nativeFrame = false;
            jitter = new MabaTemporal();

            // textureGather needs ES 3.1 / SM 4.5 class hardware; below that use the gather-free
            // fast shader for every rung (same rule as the GLSL reference).
            gather = SystemInfo.graphicsShaderLevel >= 45;
            upscaleMat = gather ? NewMaterial("Maba3Shaders/MabaUpscaler", "MABA3/Upscaler") : null;
            if (upscaleMat == null)
            {
                gather = false;
                upscaleMat = NewMaterial("Maba3Shaders/MabaUpscalerCompat", "MABA3/UpscalerCompat");
            }
            temporalMat = NewMaterial("Maba3Shaders/MabaTsr", "MABA3/Tsr");
            presentMat = NewMaterial("Maba3Shaders/MabaTsrPresent", "MABA3/TsrPresent");
            copyMat = NewMaterial("Maba3Shaders/MabaDepthCopy", "MABA3/DepthCopy");
            fgMat = NewMaterial("Maba3Shaders/MabaFgWarp", "MABA3/FgWarp");
            if (upscaleMat == null)
            {
                Debug.LogError("MABA Upscaler: upscale shader missing or unsupported on this device; component disabled.", this);
                enabled = false;
                return;
            }

            savedRect = cam.rect;
            savedDepthMode = cam.depthTextureMode;
            fpsTime = Time.unscaledTimeAsDouble;
            fpsFrames = 0;
            lastTemporal = false;
            havePrevVP = false;
            RenderPipelineManager.endCameraRendering += OnEndCameraRendering;
            CreatePresenter();
        }

        void OnDisable()
        {
            RenderPipelineManager.endCameraRendering -= OnEndCameraRendering;
            DestroyPresenter();
            fgGenerating = false;
            if (cam != null) cam.enabled = true;   // Frame Generation switches the camera off on generated frames: never leave it off
            if (cam != null && sceneRT != null)
            {
                if (cam.targetTexture == sceneRT) cam.targetTexture = null;
                cam.rect = savedRect;
                cam.depthTextureMode = savedDepthMode;
                if (projectionOverridden) cam.ResetProjectionMatrix();
            }
            RestoreUrpDepth();
            projectionOverridden = false;
            ReleaseTargets();
            DestroyMaterial(ref upscaleMat);
            DestroyMaterial(ref temporalMat);
            DestroyMaterial(ref presentMat);
            DestroyMaterial(ref fgMat);
            DestroyMaterial(ref copyMat);
        }

        // URP: remember and restore the camera's own "Depth Texture" setting.
        // URP's UniversalAdditionalCameraData is reached by reflection, so this package has no compile-time dependency on URP (an asmdef
        // reference to an assembly a project does not have is an error in Unity, and a version define cannot make it optional).
        static System.Type urpCameraData;
        static bool urpLookedUp;
        static System.Type UrpCameraDataType()
        {
            if (!urpLookedUp)
            {
                urpLookedUp = true;
                foreach (var a in System.AppDomain.CurrentDomain.GetAssemblies())
                {
                    urpCameraData = a.GetType("UnityEngine.Rendering.Universal.UniversalAdditionalCameraData", false);
                    if (urpCameraData != null) break;
                }
            }
            return urpCameraData;
        }

        void RequestUrpDepth()
        {
            var asset = GraphicsSettings.currentRenderPipeline;
            if (asset == null || !asset.GetType().Name.Contains("Universal")) return;
            var type = UrpCameraDataType();
            if (type == null) return;
            var prop = type.GetProperty("requiresDepthTexture");
            if (prop == null || !prop.CanRead || !prop.CanWrite) return;
            var data = cam.GetComponent(type);
            if (data == null) data = cam.gameObject.AddComponent(type);   // what GetUniversalAdditionalCameraData() does
            if (!haveSavedRequiresDepth)
            {
                savedRequiresDepth = (bool)prop.GetValue(data, null);
                haveSavedRequiresDepth = true;
            }
            prop.SetValue(data, true, null);
        }

        void RestoreUrpDepth()
        {
            if (!haveSavedRequiresDepth || cam == null) return;
            var type = UrpCameraDataType();
            var data = type != null ? cam.GetComponent(type) : null;
            var prop = type != null ? type.GetProperty("requiresDepthTexture") : null;
            if (data != null && prop != null) prop.SetValue(data, savedRequiresDepth, null);
            haveSavedRequiresDepth = false;
        }

        static void DestroyMaterial(ref Material m)
        {
            if (m != null) Destroy(m);
            m = null;
        }

        static void ReleaseRT(ref RenderTexture rt)
        {
            if (rt == null) return;
            rt.Release();
            Destroy(rt);
            rt = null;
        }

        void ReleaseTemporalTargets()
        {
            for (int i = 0; i < 2; i++)
            {
                ReleaseRT(ref histRT[i]);
                ReleaseRT(ref outDepthRT[i]);
            }
            ReleaseRT(ref shownRT);
            ReleaseRT(ref depthCurRT);
            outRtW = outRtH = 0;
        }

        void ReleaseTargets()
        {
            ReleaseRT(ref sceneRT);
            ReleaseTemporalTargets();
        }

        // Same rounding as the C header: (int)(x * scale + 0.5).
        static int Scaled(int size, float scale) { return (int)(size * scale + 0.5f); }

        void EnsureTargets(int sw, int sh)
        {
            // Sized for the largest rung the controller can ask for: the top of the Dynamic range,
            // or a fixed preset's own rung when that is higher (presets ignore the range). It used
            // to be the classic 0.77 ceiling, which would have silently clamped the render region
            // once Dynamic mode may climb to native. Changing maxScale or the mode at run time
            // reallocates the textures. They are only created once a frame actually needs them
            // (see LateUpdate), so a game that stays at native never pays for them.
            float topScale = MabaController.RungScale(Mathf.Max(ctrl.RungHi, ctrl.Rung));
            int w = Mathf.Max(2, Scaled(sw, topScale)), h = Mathf.Max(2, Scaled(sh, topScale));
            if (sceneRT != null && texW == w && texH == h) return;
            if (cam.targetTexture == sceneRT) cam.targetTexture = null;
            ReleaseTargets();
            texW = w; texH = h;
            sceneRT = new RenderTexture(w, h, 24, RenderTextureFormat.ARGB32);
            sceneRT.name = "MABA Scene";
            sceneRT.filterMode = FilterMode.Bilinear;
            sceneRT.wrapMode = TextureWrapMode.Clamp;
            sceneRT.useMipMap = false;
            sceneRT.Create();
            jitter.Reset();
            havePrevVP = false;
        }

        void EnsureTemporalTargets(int sw, int sh)
        {
            if (histRT[0] != null && outRtW == sw && outRtH == sh && depthCurRT != null && depthCurRT.width == texW && depthCurRT.height == texH) return;
            ReleaseTemporalTargets();
            outRtW = sw; outRtH = sh;
            RenderTextureFormat depthFormat =
                SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.RFloat) ? RenderTextureFormat.RFloat
                : RenderTextureFormat.RHalf;
            RenderTextureFormat histFormat =
                SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.ARGBHalf) ? RenderTextureFormat.ARGBHalf
                : RenderTextureFormat.ARGB32;
            // The three targets of the resolve pass (history, shown image, depth) are the same size, as
            // multiple render targets require. Only the shown image carries a (unused) depth buffer.
            shownRT = new RenderTexture(sw, sh, 16, histFormat, RenderTextureReadWrite.Linear);
            shownRT.name = "MABA Shown";
            shownRT.filterMode = FilterMode.Point;
            shownRT.wrapMode = TextureWrapMode.Clamp;
            shownRT.Create();
            for (int i = 0; i < 2; i++)
            {
                histRT[i] = new RenderTexture(sw, sh, 0, histFormat, RenderTextureReadWrite.Linear);
                histRT[i].name = "MABA History " + i;
                histRT[i].filterMode = FilterMode.Bilinear;
                histRT[i].wrapMode = TextureWrapMode.Clamp;
                histRT[i].Create();
                // Depth is stored as data, never colour-converted.
                outDepthRT[i] = new RenderTexture(sw, sh, 0, depthFormat, RenderTextureReadWrite.Linear);
                outDepthRT[i].name = "MABA Depth " + i;
                outDepthRT[i].filterMode = FilterMode.Point;
                outDepthRT[i].wrapMode = TextureWrapMode.Clamp;
                outDepthRT[i].Create();
            }
            depthCurRT = new RenderTexture(texW, texH, 0, depthFormat, RenderTextureReadWrite.Linear);
            depthCurRT.name = "MABA Scene Depth";
            depthCurRT.filterMode = FilterMode.Point;
            depthCurRT.wrapMode = TextureWrapMode.Clamp;
            depthCurRT.Create();
            jitter.Reset();
            havePrevVP = false;
        }
        void LateUpdate()
        {
            int sw = Screen.width, sh = Screen.height;
            if (sw < 4 || sh < 4 || upscaleMat == null) return;

            // Frame Generation: is this frame generated (no render, the last real frame re-projected) or real?
            GovUpdate(Time.unscaledDeltaTime * 1000f, Time.unscaledDeltaTime);
            bool generated = FgDecide();
            fgGenerating = generated;
            if (cam.enabled == generated) cam.enabled = !generated;
            if (presentCam != null && presentCam.enabled != generated) presentCam.enabled = generated;
            if (generated)
            {
                // The warp needs the plain camera: no jitter.
                if (projectionOverridden)
                {
                    cam.ResetProjectionMatrix();
                    projectionOverridden = false;
                }
                CountFrame();
                return;
            }
            // SetScaleRange resets the controller's counters, so apply it only when it changed.
            if (minScale != appliedMinScale || maxScale != appliedMaxScale)
            {
                ctrl.SetScaleRange(minScale, maxScale);
                appliedMinScale = minScale;
                appliedMaxScale = maxScale;
            }

            // GPU-only time where the platform reports it, present-to-present otherwise.
            float ms = Time.unscaledDeltaTime * 1000f;
            gpuMs = 0f;
            FrameTimingManager.CaptureFrameTimings();
            if (FrameTimingManager.GetLatestTimings(1, timings) > 0 && timings[0].gpuFrameTime > 0.0)
            {
                gpuMs = (float)timings[0].gpuFrameTime;
                ms = gpuMs;
            }

            // SetTargetFps and SetMode reset the controller's counters, so only call them when
            // the setting actually changed; calling them every frame would freeze Dynamic mode.
            if (targetFps != appliedTargetFps)
            {
                ctrl.SetTargetFps(targetFps);
                appliedTargetFps = targetFps;
            }
            if (ctrl.Mode != (int)mode) ctrl.SetMode((int)mode);
            // The controller holds a DISPLAYED frame rate: with Frame Generation one real frame covers several displayed ones.
            int fgFactor = FgFactor();
            ctrl.BeginFrame(fgFactor > 1 ? ms / fgFactor : ms);
            if (ctrl.Scale != lastScale)
            {
                lastScale = ctrl.Scale;
                if (ScaleChanged != null) ScaleChanged(lastScale);
            }

            temporalActive = temporal && temporalMat != null && presentMat != null && copyMat != null && !cam.orthographic;

            // Native resolution (scale 1.00) without the temporal tier has nothing to upscale: the
            // camera renders straight to the screen and the upscale pass is skipped.
            nativeFrame = ctrl.IsNative && !temporalActive;
            if (nativeFrame)
            {
                if (cam.targetTexture == sceneRT) cam.targetTexture = null;
                cam.rect = savedRect;
                StopTemporal();
                lastTemporal = false;
                rw = lastRw = sw;
                rh = lastRh = sh;
                return;
            }

            // The scene texture follows the (possibly just changed) mode and range, so size it
            // after the controller has moved.
            EnsureTargets(sw, sh);
            float scale = ctrl.Scale;
            rw = Mathf.Clamp(Scaled(sw, scale), 2, texW);
            rh = Mathf.Clamp(Scaled(sh, scale), 2, texH);

            // Render into the bottom-left rw x rh texels of the fixed-size texture. pixelRect is
            // relative to the target texture, so the region is exact.
            cam.targetTexture = sceneRT;
            cam.pixelRect = new Rect(0, 0, rw, rh);

            if (temporalActive)
            {
                EnsureTemporalTargets(sw, sh);
                cam.depthTextureMode |= DepthTextureMode.Depth;
                RequestUrpDepth();
                if (rw != lastRw || rh != lastRh || !lastTemporal)
                {
                    jitter.Reset();
                    havePrevVP = false;
                }
                jitter.ClipGamma = clipGamma;
                jitter.DepthTolerance = depthTolerance;
                MabaTemporal.Frame jf = jitter.BeginFrame();

                // Start from the camera's own projection for this region, then shift it by a
                // sub-texel amount. Unity matrices are [row, column], GL convention.
                cam.ResetProjectionMatrix();
                plainProj = cam.projectionMatrix;
                Matrix4x4 proj = plainProj;
                // The content must move BY +jitter texels. For a perspective projection (clip.w = -z)
                // adding d to column 2 shifts NDC by -d, so SUBTRACT; an orthographic projection
                // is shifted through its translation column and ADDS.
                if (cam.orthographic)
                {
                    proj[0, 3] += 2f * jf.JitterX / rw;
                    proj[1, 3] += 2f * jf.JitterY / rh;
                }
                else
                {
                    proj[0, 2] -= 2f * jf.JitterX / rw;
                    proj[1, 2] -= 2f * jf.JitterY / rh;
                }
                jitterTexels = new Vector2(jf.JitterX, jf.JitterY);
                cam.projectionMatrix = proj;
                projectionOverridden = true;
            }
            else
            {
                StopTemporal();
            }
            lastTemporal = temporalActive;
            lastRw = rw;
            lastRh = rh;
        }

        // The temporal tier is off for this frame: undo its projection jitter, and release its
        // textures and depth request the first time it stops.
        void StopTemporal()
        {
            if (projectionOverridden)
            {
                cam.ResetProjectionMatrix();
                projectionOverridden = false;
            }
            if (lastTemporal)
            {
                ReleaseTemporalTargets();
                cam.depthTextureMode = savedDepthMode;   // stop paying for a depth texture
                RestoreUrpDepth();
            }
            havePrevVP = false;
        }

        // Built-in render pipeline.
        void OnPostRender()
        {
            if (GraphicsSettings.currentRenderPipeline == null) Upscale();
        }

        // URP / other scriptable pipelines (they do not send OnPostRender).
        void OnEndCameraRendering(ScriptableRenderContext context, Camera camera)
        {
            if (camera == cam) Upscale();
            else if (presentCam != null && camera == presentCam) PresentGenerated();
        }

        static void DrawFullscreen(Material mat, int pass, RenderTexture target, int w, int h)
        {
            Graphics.SetRenderTarget(target);
            GL.Viewport(new Rect(0, 0, w, h));
            mat.SetPass(pass);
            Graphics.DrawProceduralNow(MeshTopology.Triangles, 3);
        }

        void CountFrame()
        {
            fpsFrames++;
            double now = Time.unscaledTimeAsDouble;
            if (fpsFrames >= 60 && now > fpsTime)
            {
                fps = (float)(fpsFrames / (now - fpsTime));
                fpsFrames = 0;
                fpsTime = now;
            }
        }

        void Upscale()
        {
            if (nativeFrame)
            {
                CountFrame();   // rendered straight to the screen: no upscale pass
                return;
            }
            if (sceneRT == null || upscaleMat == null || rw < 2 || rh < 2) return;
            if (cam.targetTexture != sceneRT) return;   // LateUpdate has not run for this frame

            Texture src = sceneRT;
            bool ranTsr = false;
            if (temporalActive && histRT[0] != null && presentMat != null)
            {
                int prev = 1 - slot;
                Matrix4x4 vp = plainProj * cam.worldToCameraMatrix;   // unjittered, GL convention
                bool reset = !havePrevVP;

                // 1. This frame's depth, converted to GL window depth (0 near .. 1 far) in the render
                //    region. The shader reads the pipeline's global _CameraDepthTexture directly: URP
                //    binds it from a command buffer, where Shader.GetGlobalTexture cannot see it.
                copyMat.SetVector(RegionId, new Vector4(rw, rh, 0, 0));
                copyMat.SetFloat(ReversedZId, SystemInfo.usesReversedZBuffer ? 1f : 0f);
                DrawFullscreen(copyMat, 0, depthCurRT, rw, rh);

                // 2. Temporal super-resolution at OUTPUT resolution: history, shown image and depth.
                temporalMat.SetTexture(InputId, sceneRT);
                temporalMat.SetTexture(HistoryId, histRT[prev]);
                temporalMat.SetTexture(DepthId, depthCurRT);
                temporalMat.SetTexture(PrevDepthId, outDepthRT[prev]);
                temporalMat.SetMatrix(InvVPId, vp.inverse);
                temporalMat.SetMatrix(PrevVPId, havePrevVP ? prevVP : vp);
                temporalMat.SetVector(TParamsId, new Vector4(0f, jitter.DepthTolerance, reset ? 1f : 0f, jitter.ClipGamma));
                temporalMat.SetVector(RegionId, new Vector4(rw, rh, 0, 0));
                temporalMat.SetVector(OutInfoId, new Vector4(outRtW, outRtH, 1f / outRtW, 1f / outRtH));
                temporalMat.SetVector(JitterId, new Vector4(jitterTexels.x, jitterTexels.y, 0, 0));
                temporalMat.SetVector(DepthRangeId, new Vector4(cam.nearClipPlane, cam.farClipPlane, 0, 0));
                if (!cam.orthographic)
                {
                    RenderBuffer[] targets = { histRT[slot].colorBuffer, shownRT.colorBuffer, outDepthRT[slot].colorBuffer };
                    Graphics.SetRenderTarget(targets, shownRT.depthBuffer);
                    GL.Viewport(new Rect(0, 0, outRtW, outRtH));
                    temporalMat.SetPass(0);
                    Graphics.DrawProceduralNow(MeshTopology.Triangles, 3);
                    ranTsr = true;
                }

                prevVP = vp;
                havePrevVP = true;
                fgHaveReal = ranTsr;
                slot = prev;
            }
            else
            {
                havePrevVP = false;   // temporal off: restart accumulation when it returns
                fgHaveReal = false;
            }

            if (ranTsr)
            {
                // 3a. Sharpen the temporal result straight into the screen (clamped to the local range).
                presentMat.SetTexture(ShownId, shownRT);
                presentMat.SetVector(OutInfoId, new Vector4(outRtW, outRtH, 1f / outRtW, 1f / outRtH));
                presentMat.SetVector(ParamsId, new Vector4(sharpness * 0.12f, 0, 0, 0));
                DrawFullscreen(presentMat, 0, null, Screen.width, Screen.height);
                CountFrame();
                return;
            }
            // 3b. Spatial fallback: upscale the region to the screen.
            upscaleMat.SetTexture(InputId, src);
            upscaleMat.SetVector(InputSizeId, new Vector4(rw, rh, 1f / texW, 1f / texH));
            upscaleMat.SetVector(ParamsId, new Vector4(sharpness, 0, 0, 0));
            DrawFullscreen(upscaleMat, gather && ctrl.QualityShader ? 1 : 0, null, Screen.width, Screen.height);
            CountFrame();
        }

        // ---- Settings API ----------------------------------------------------------------------------------

        /// <summary>The settings in force now.</summary>
        public MabaUserSettings GetSettings()
        {
            MabaUserSettings s;
            s.mode = mode;
            s.sharpness = sharpness;
            s.targetFps = targetFps;
            s.minScale = minScale;
            s.maxScale = maxScale;
            s.temporal = temporal;
            s.frameGeneration = frameGeneration;
            s.frameGenerationAutoPause = frameGenerationAutoPause;
            return s;
        }

        /// <summary>Applies a whole settings value (values are clamped). Pair it with <see cref="MabaSettings.Save"/> to keep it.</summary>
        public void Apply(MabaUserSettings settings)
        {
            ApplyFields(settings);
        }

        void ApplyFields(MabaUserSettings settings)
        {
            settings = settings.Clamped();
            mode = settings.mode;
            sharpness = settings.sharpness;
            targetFps = settings.targetFps;
            minScale = settings.minScale;
            maxScale = settings.maxScale;
            temporal = settings.temporal;
            frameGeneration = settings.frameGeneration;
            frameGenerationAutoPause = settings.frameGenerationAutoPause;
        }

        /// <summary>Choose Off, 2x or 3x Frame Generation.</summary>
        public void SetFrameGeneration(FrameGeneration value) { frameGeneration = value; }

        /// <summary>True while the current frame is a generated one (not rendered, re-projected).</summary>
        public bool FrameGenerationActive { get { return fgGenerating; } }

        /// <summary>Frame Generation was asked for but the governor paused it (it would not show more frames per second).</summary>
        public bool FrameGenerationPaused { get { return frameGeneration != FrameGeneration.Off && frameGenerationAutoPause && govState == 2; } }

        // ---- Frame Generation ------------------------------------------------------------------------------

        int FgFactor()
        {
            if (frameGeneration == FrameGeneration.Off || fgMat == null || cam == null) return 1;
            if (!temporalActive || nativeFrame || cam.orthographic) return 1;
            if (frameGenerationAutoPause && govState != 0) return 1;     // probing without it, or paused
            return frameGeneration == FrameGeneration.X2 ? 2 : 3;
        }

        // Decides, before the engine renders, whether this frame is generated. Real frames come first.
        bool FgDecide()
        {
            int factor = FgFactor();
            if (factor <= 1 || !fgHaveReal || !havePrevVP || shownRT == null || outDepthRT[0] == null)
            {
                fgPhase = factor > 1 ? 1 % factor : 0;
                return false;
            }
            bool generated = fgPhase != 0;
            fgPhase = (fgPhase + 1) % factor;
            return generated;
        }

        // Governor: Frame Generation must never show fewer frames per second than leaving it off. While it runs it measures the
        // ms per displayed frame; every GovPeriodS it renders every frame for a few frames to measure a real frame alone, and
        // pauses itself when generating would not cut the ms per displayed frame by at least 8%.
        void GovUpdate(float frameMs, float dt)
        {
            if (frameGeneration == FrameGeneration.Off || !frameGenerationAutoPause)
            {
                govState = 0; govTimer = GovPeriodS; govSamples = 0; govSum = 0f;
                return;
            }
            switch (govState)
            {
                case 0:
                    if (fgHaveReal) { govSum += frameMs; govSamples++; }
                    govTimer -= dt;
                    if (govTimer <= 0f && govSamples > 60)
                    {
                        govOnMs = govSum / govSamples;
                        govState = 1; govSamples = 0; govSum = 0f;
                    }
                    break;
                case 1:
                    govSamples++;
                    if (govSamples > 3) govSum += frameMs;           // skip the transition frames
                    if (govSamples >= GovProbeFrames)
                    {
                        govOffMs = govSum / (GovProbeFrames - 3);
                        govSamples = 0; govSum = 0f;
                        if (govOnMs < govOffMs * GovMargin) { govState = 0; govTimer = GovPeriodS; }
                        else { govState = 2; govTimer = GovPauseS; }
                    }
                    break;
                default:
                    govTimer -= dt;
                    if (govTimer <= 0f) { govState = 0; govTimer = 6f; govSamples = 0; govSum = 0f; }
                    break;
            }
        }

        // A hidden child camera presents the generated frames (the main camera is off on those frames, so it sends no render callbacks).
        void CreatePresenter()
        {
            if (fgMat == null || presentGo != null) return;
            presentGo = new GameObject("MABA Frame Generation Present");
            presentGo.hideFlags = HideFlags.HideAndDontSave;
            presentGo.transform.SetParent(transform, false);
            presentCam = presentGo.AddComponent<Camera>();
            presentCam.cullingMask = 0;
            presentCam.clearFlags = CameraClearFlags.Nothing;
            presentCam.depth = cam.depth + 1f;
            presentCam.allowMSAA = false;
            presentCam.useOcclusionCulling = false;
            presentCam.enabled = false;
            var hook = presentGo.AddComponent<MabaPresenterHook>();
            hook.owner = this;
        }

        void DestroyPresenter()
        {
            if (presentGo != null) Destroy(presentGo);
            presentGo = null;
            presentCam = null;
        }

        /// <summary>Called by the hidden present camera: draws the generated frame into the screen.</summary>
        internal void PresentGenerated()
        {
            if (!fgGenerating || fgMat == null || shownRT == null || outDepthRT[0] == null || cam == null) return;
            // The depth the last temporal pass wrote is the one of the slot that is NOT written next.
            RenderTexture depth = outDepthRT[1 - slot];
            Matrix4x4 plain = cam.projectionMatrix;                  // the plain (unjittered) projection: reset when this frame was decided
            Matrix4x4 newVP = plain * cam.worldToCameraMatrix;
            fgMat.SetTexture(ShownId, shownRT);
            fgMat.SetTexture(OutDepthId, depth);
            fgMat.SetMatrix(LastVPId, prevVP);
            fgMat.SetMatrix(LastInvVPId, prevVP.inverse);
            fgMat.SetMatrix(NewVPId, newVP);
            fgMat.SetMatrix(NewInvVPId, newVP.inverse);
            fgMat.SetVector(OutInfoId, new Vector4(outRtW, outRtH, 1f / outRtW, 1f / outRtH));
            fgMat.SetVector(ParamsId, new Vector4(sharpness * 0.12f, 0, 0, 0));
            DrawFullscreen(fgMat, 0, null, Screen.width, Screen.height);
        }

        /// <summary>Call on camera cuts / teleports so the temporal tier drops its history.</summary>
        public void ResetHistory()
        {
            if (jitter != null) jitter.Reset();
            havePrevVP = false;
        }

        void OnGUI()
        {
            if (!debugOverlay || ctrl == null) return;
            GUI.Label(new Rect(8, 8, 700, 24),
                string.Format("MABA {0}{1} | scale {2:0.00} {3} | {4:0} fps | gpu {5:0.0} ms",
                    mode, temporalActive ? " +temporal" : "", ctrl.Scale,
                    nativeFrame ? "native" : (gather && ctrl.QualityShader ? "quality" : "fast"), fps, gpuMs));
        }
    }

    /// <summary>Forwards the built-in pipeline's OnPostRender of the hidden present camera to the component.</summary>
    [AddComponentMenu("")]
    internal sealed class MabaPresenterHook : MonoBehaviour
    {
        internal MabaUpscaler owner;

        void OnPostRender()
        {
            if (owner != null && GraphicsSettings.currentRenderPipeline == null) owner.PresentGenerated();
        }
    }
}
