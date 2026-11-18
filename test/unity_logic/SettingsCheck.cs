// Logic checks for the Unity settings API, run against the stub UnityEngine (real arithmetic, no engine).
using System;
using UnityEngine;
using Maba3;

static class SettingsCheck
{
    static int failures;
    static void Check(bool ok, string what) { if (!ok) { Console.WriteLine("FAIL  " + what); failures++; } }

    static int Main()
    {
        // presets for a screen
        var infos = MabaSettings.GetModeInfos(new Vector2Int(1920, 1080));
        Check(infos.Length == 5, "five presets");
        Check(infos[0].mode == MabaUpscaler.Mode.Dynamic && !infos[0].fixedScale && infos[0].scale == 1f, "Dynamic reports scale 1 and is not fixed");
        MabaModeInfo bal = MabaSettings.GetModeInfo(MabaUpscaler.Mode.Balanced, new Vector2Int(1920, 1080));
        Check(Math.Abs(bal.scale - 0.59f) < 1e-6f && bal.renderSize.x == 1133 && bal.renderSize.y == 637 && bal.name == "Balanced", "Balanced 0.59 -> 1133 x 637");
        Check(Math.Abs(MabaSettings.GetModeInfo(MabaUpscaler.Mode.UltraQuality, new Vector2Int(1000, 1000)).scale - 0.77f) < 1e-6f, "Ultra Quality 0.77");
        Check(Math.Abs(MabaSettings.GetModeInfo(MabaUpscaler.Mode.Quality, new Vector2Int(1000, 1000)).scale - 0.67f) < 1e-6f, "Quality 0.67");
        Check(Math.Abs(MabaSettings.GetModeInfo(MabaUpscaler.Mode.Performance, new Vector2Int(1000, 1000)).scale - 0.50f) < 1e-6f, "Performance 0.50");
        Check(MabaSettings.GetModeInfo(MabaUpscaler.Mode.Performance, new Vector2Int(1, 1)).renderSize.x == 2, "render size never below 2");

        // recommended preset by screen size
        Check(MabaSettings.RecommendedMode(new Vector2Int(3840, 2160)) == MabaUpscaler.Mode.Performance, "4K -> Performance");
        Check(MabaSettings.RecommendedMode(new Vector2Int(2560, 1440)) == MabaUpscaler.Mode.Balanced, "1440p -> Balanced");
        Check(MabaSettings.RecommendedMode(new Vector2Int(1920, 1080)) == MabaUpscaler.Mode.Quality, "1080p -> Quality");
        Check(MabaSettings.RecommendedMode(new Vector2Int(1280, 720)) == MabaUpscaler.Mode.UltraQuality, "720p -> Ultra Quality");

        // clamping
        MabaUserSettings d = MabaUserSettings.Defaults;
        Check(d.mode == MabaUpscaler.Mode.Dynamic && d.sharpness == 0.5f && d.targetFps == 60f && d.temporal && d.frameGeneration == FrameGeneration.Off && d.frameGenerationAutoPause, "defaults");
        MabaUserSettings bad = d;
        bad.sharpness = 7f; bad.targetFps = 1f; bad.minScale = 0.9f; bad.maxScale = 0.4f;
        bad.mode = (MabaUpscaler.Mode)42; bad.frameGeneration = (FrameGeneration)9;
        MabaUserSettings c = bad.Clamped();
        Check(c.sharpness == 1f && c.targetFps == 15f, "sharpness and fps clamped");
        Check(c.maxScale >= c.minScale && c.minScale == 0.9f, "max scale is never below min scale");
        Check(c.mode == MabaUpscaler.Mode.Dynamic && c.frameGeneration == FrameGeneration.Off, "invalid enum values fall back");
        MabaUserSettings ok = d; ok.mode = MabaUpscaler.Mode.Quality; ok.frameGeneration = FrameGeneration.X3; ok.targetFps = 144f;
        MabaUserSettings okc = ok.Clamped();
        Check(okc.mode == MabaUpscaler.Mode.Quality && okc.frameGeneration == FrameGeneration.X3 && okc.targetFps == 144f, "valid values are kept");

        if (failures == 0) Console.WriteLine("ALL UNITY SETTINGS CHECKS PASSED");
        return failures == 0 ? 0 : 1;
    }
}