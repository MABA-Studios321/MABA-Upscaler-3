// MABA Upscaler - C# port of the dynamic controller in maba_upscaler.h.
// Kept line-for-line in sync; parity-tested against the C header on the host (test/native).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
namespace Maba3
{
    public sealed class MabaController
    {
        /// <summary>The whole ladder: scale 0.35 (rung -15) .. 1.00 = native (rung 51).</summary>
        public const int RungFloor = -15, RungCeil = 51;
        /// <summary>The span of the classic presets (0.50..0.77): their anchors, no longer a limit on Dynamic.</summary>
        public const int RungCount = 29;
        public const int RungMin = 0, RungMax = RungCount - 1;

        public const int ModeDynamic = 0, ModeUltraQuality = 1, ModeQuality = 2,
            ModeBalanced = 3, ModePerformance = 4;

        public const int StartRung = 10;
        public const float OverRatio = 1.02f;
        public const int DownFrames = 20, UpFrames = 180, UpFramesMax = 3600, ProvenFrames = 300;
        /// <summary>A multi-rung step up must be predicted to use at most this share of the frame budget.</summary>
        public const float Headroom = 0.90f;
        /// <summary>Most rungs one step up may climb.</summary>
        public const int MaxJump = 16;

        public int Mode;
        public float TargetMs;
        public int Rung;
        public float AvgMs;
        public int OverFrames, GoodFrames, UpWait;
        public bool Probing;
        /// <summary>The range Dynamic mode may use (default: the whole ladder).</summary>
        public int RungLo, RungHi;
        /// <summary>The rung the current step up started from.</summary>
        public int ProbeFrom;

        public MabaController(int mode, float targetFps)
        {
            TargetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
            RungLo = RungFloor;
            RungHi = RungCeil;
            SetMode(mode);
        }

        /// <summary>Render scale of a rung in whole percent (exact).</summary>
        public static int RungPercent(int rung)
        {
            return (rung <= 9) ? (50 + rung) : (49 + rung);
        }

        public static float RungScale(int rung)
        {
            return (float)RungPercent(rung) * 0.01f;
        }

        public static bool RungQuality(int rung) { return rung >= 10; }

        /// <summary>True at scale 1.00: render at output size and skip the upscale pass.</summary>
        public static bool RungNative(int rung) { return RungPercent(rung) >= 100; }

        /// <summary>The rung closest to a render scale (0.35..1.00). 0.59 maps to the quality build (rung 10).</summary>
        public static int ScaleToRung(float scale)
        {
            int pct = (int)(scale * 100f + 0.5f);
            if (pct < 35) pct = 35;
            if (pct > 100) pct = 100;
            return (pct <= 58) ? (pct - 50) : (pct - 49);
        }

        public static int ModeRung(int mode)
        {
            switch (mode)
            {
                case ModeUltraQuality: return 28;
                case ModeQuality: return 18;
                case ModeBalanced: return 10;
                case ModePerformance: return 0;
                default: return StartRung;
            }
        }

        public float Scale { get { return RungScale(Rung); } }
        public bool QualityShader { get { return RungQuality(Rung); } }
        public bool IsNative { get { return RungNative(Rung); } }

        int ClampRung(int rung)
        {
            if (rung < RungLo) rung = RungLo;
            if (rung > RungHi) rung = RungHi;
            return rung;
        }

        public void SetMode(int mode)
        {
            Mode = mode;
            Rung = ModeRung(mode);
            if (mode == ModeDynamic) Rung = ClampRung(Rung);   // presets are explicit
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            UpWait = UpFrames;
            Probing = false;
            ProbeFrom = Rung;
        }

        /// <summary>Restrict Dynamic mode to a render-scale range. In Dynamic mode the rung moves inside it.</summary>
        public void SetScaleRange(float minScale, float maxScale)
        {
            int lo = ScaleToRung(minScale);
            int hi = ScaleToRung(maxScale);
            if (hi < lo) hi = lo;
            RungLo = lo;
            RungHi = hi;
            if (Mode == ModeDynamic) Rung = ClampRung(Rung);
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            Probing = false;
            ProbeFrom = Rung;
        }

        public void SetTargetFps(float fps)
        {
            TargetMs = 1000f / (fps > 1f ? fps : 60f);
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            Probing = false;
        }

        public void SeedRung(int rung)
        {
            Rung = ClampRung(rung);
            AvgMs = 0f;
            OverFrames = 0;
            GoodFrames = 0;
            Probing = false;
            ProbeFrom = Rung;
        }

        public void UpdateDynamic(float frameMs)
        {
            if (frameMs <= 0f || frameMs > 1000f) return;
            AvgMs = AvgMs <= 0f ? frameMs : AvgMs + (frameMs - AvgMs) * 0.1f;
            if (AvgMs > TargetMs * OverRatio)
            {
                GoodFrames = 0;
                if (++OverFrames >= DownFrames && Rung > RungLo)
                {
                    int next = Rung - 1;
                    if (Probing)
                    {
                        // A failed step up returns to the rung it started from, in one step.
                        if (ProbeFrom < Rung && ProbeFrom >= RungLo) next = ProbeFrom;
                        UpWait = System.Math.Min(UpWait * 2, UpFramesMax);
                        Probing = false;
                    }
                    Rung = next;
                    OverFrames = 0;
                    AvgMs = TargetMs;
                }
            }
            else
            {
                OverFrames = 0;
                GoodFrames++;
                if (Probing && GoodFrames >= ProvenFrames)
                {
                    Probing = false;
                    UpWait = System.Math.Max(UpFrames, UpWait / 2);
                }
                if (!Probing && GoodFrames >= UpWait && Rung < RungHi)
                {
                    // One rung, or several when the measured frame time says they fit: the time at a
                    // higher rung is predicted as if the whole frame scaled with the pixel count.
                    int cur = RungPercent(Rung);
                    int next = Rung + 1;
                    for (int r = Rung + 2; r <= RungHi && r <= Rung + MaxJump; r++)
                    {
                        int p = RungPercent(r);
                        if (AvgMs * (float)(p * p) / (float)(cur * cur) > TargetMs * Headroom) break;
                        next = r;
                    }
                    ProbeFrom = Rung;
                    Rung = next;
                    GoodFrames = 0;
                    Probing = true;
                }
            }
        }

        public int BeginFrame(float lastFrameMs)
        {
            if (Mode == ModeDynamic) UpdateDynamic(lastFrameMs);
            return Rung;
        }
    }
}
