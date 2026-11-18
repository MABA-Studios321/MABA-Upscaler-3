// MABA Upscaler 3 - settings API for Unity: capability and preset queries, the recommended preset for a screen, and the
// player's saved choices. Everything here is static, so any menu (uGUI, UI Toolkit, IMGUI, your own) can use it.
//
//   var maba = Camera.main.GetComponent<MabaUpscaler>();
//   MabaSettings.TryLoad(out var saved);  maba.Apply(saved);       // at start-up (MabaUpscaler does this itself when
//                                                                  // "Use Saved Settings" is on)
//   maba.Apply(settings);  MabaSettings.Save(settings);            // after the player changed something
//
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System;
using UnityEngine;

namespace Maba3
{
    /// <summary>Frame Generation: extra frames between the rendered ones.</summary>
    public enum FrameGeneration { Off, X2, X3 }

    /// <summary>Everything a player can change, as one value.</summary>
    [Serializable]
    public struct MabaUserSettings
    {
        public MabaUpscaler.Mode mode;
        [Range(0f, 1f)] public float sharpness;
        public float targetFps;
        [Range(0.35f, 1f)] public float minScale;
        [Range(0.35f, 1f)] public float maxScale;
        public bool temporal;
        public FrameGeneration frameGeneration;
        public bool frameGenerationAutoPause;

        public static MabaUserSettings Defaults
        {
            get
            {
                MabaUserSettings s;
                s.mode = MabaUpscaler.Mode.Dynamic;
                s.sharpness = 0.5f;
                s.targetFps = 60f;
                s.minScale = 0.35f;
                s.maxScale = 1f;
                s.temporal = true;
                s.frameGeneration = FrameGeneration.Off;
                s.frameGenerationAutoPause = true;
                return s;
            }
        }

        /// <summary>The same settings with every value brought into its valid range.</summary>
        public MabaUserSettings Clamped()
        {
            MabaUserSettings s = this;
            s.sharpness = Mathf.Clamp(s.sharpness, 0f, 1f);
            s.targetFps = Mathf.Clamp(s.targetFps, 15f, 240f);
            s.minScale = Mathf.Clamp(s.minScale, 0.35f, 1f);
            s.maxScale = Mathf.Clamp(s.maxScale, s.minScale, 1f);
            if ((int)s.mode < 0 || (int)s.mode > 4) s.mode = MabaUpscaler.Mode.Dynamic;
            if ((int)s.frameGeneration < 0 || (int)s.frameGeneration > 2) s.frameGeneration = FrameGeneration.Off;
            return s;
        }
    }

    /// <summary>One quality preset, for building a menu.</summary>
    public struct MabaModeInfo
    {
        public MabaUpscaler.Mode mode;
        public string name;
        /// <summary>Render scale; Dynamic reports 1 (its highest) because the controller moves it.</summary>
        public float scale;
        /// <summary>The 3D render resolution for the output size that was asked about.</summary>
        public Vector2Int renderSize;
        /// <summary>False for Dynamic (the scale follows the target frame rate).</summary>
        public bool fixedScale;
    }

    public static class MabaSettings
    {
        const string PrefsKey = "MABA3.UserSettings";

        /// <summary>Raised by Save and Reset, so open menus can refresh.</summary>
        public static event Action<MabaUserSettings> Changed;

        /// <summary>True when the upscaler can run here (a graphics device that supports the shaders).</summary>
        public static bool IsSupported()
        {
            return SystemInfo.graphicsDeviceType != UnityEngine.Rendering.GraphicsDeviceType.Null && SystemInfo.graphicsShaderLevel >= 30;
        }

        /// <summary>True when temporal super-resolution can run (needs ES 3.1 / SM 4.5 class hardware and a depth texture).</summary>
        public static bool IsTemporalSupported()
        {
            return IsSupported() && SystemInfo.graphicsShaderLevel >= 35 && SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.RFloat);
        }

        /// <summary>True when Frame Generation can run: temporal support plus multiple render targets.</summary>
        public static bool IsFrameGenerationSupported()
        {
            return IsTemporalSupported() && SystemInfo.supportedRenderTargetCount >= 3;
        }

        public static MabaModeInfo GetModeInfo(MabaUpscaler.Mode mode, Vector2Int output)
        {
            MabaModeInfo info;
            info.mode = mode;
            info.fixedScale = mode != MabaUpscaler.Mode.Dynamic;
            info.scale = info.fixedScale ? MabaController.RungScale(MabaController.ModeRung((int)mode)) : 1f;
            switch (mode)
            {
                case MabaUpscaler.Mode.UltraQuality: info.name = "Ultra Quality"; break;
                case MabaUpscaler.Mode.Quality: info.name = "Quality"; break;
                case MabaUpscaler.Mode.Balanced: info.name = "Balanced"; break;
                case MabaUpscaler.Mode.Performance: info.name = "Performance"; break;
                default: info.name = "Dynamic"; break;
            }
            info.renderSize = new Vector2Int(Mathf.Max(2, Mathf.RoundToInt(output.x * info.scale)),
                Mathf.Max(2, Mathf.RoundToInt(output.y * info.scale)));
            return info;
        }

        /// <summary>Every preset with its render scale and render resolution for <paramref name="output"/>.</summary>
        public static MabaModeInfo[] GetModeInfos(Vector2Int output)
        {
            var list = new MabaModeInfo[5];
            for (int m = 0; m < 5; m++) list[m] = GetModeInfo((MabaUpscaler.Mode)m, output);
            return list;
        }

        /// <summary>A starting preset for a screen: the more pixels, the lower the render scale. A heuristic by size only; Dynamic is the one that adapts.</summary>
        public static MabaUpscaler.Mode RecommendedMode(Vector2Int output)
        {
            long pixels = (long)output.x * output.y;
            if (pixels >= 8000000L) return MabaUpscaler.Mode.Performance;      // 4K and above
            if (pixels >= 3500000L) return MabaUpscaler.Mode.Balanced;         // 1440p
            if (pixels >= 1900000L) return MabaUpscaler.Mode.Quality;          // 1080p
            return MabaUpscaler.Mode.UltraQuality;
        }

        /// <summary>Stores the settings in PlayerPrefs (JSON).</summary>
        public static void Save(MabaUserSettings settings)
        {
            settings = settings.Clamped();
            try
            {
                PlayerPrefs.SetString(PrefsKey, JsonUtility.ToJson(settings));
                PlayerPrefs.Save();
            }
            catch (Exception e)
            {
                Debug.LogWarning("MABA: could not save the settings: " + e.Message);
            }
            if (Changed != null) Changed(settings);
        }

        /// <summary>Reads what the player saved. Returns false when nothing (usable) was saved.</summary>
        public static bool TryLoad(out MabaUserSettings settings)
        {
            settings = MabaUserSettings.Defaults;
            try
            {
                if (!PlayerPrefs.HasKey(PrefsKey)) return false;
                string json = PlayerPrefs.GetString(PrefsKey);
                if (string.IsNullOrEmpty(json)) return false;
                settings = JsonUtility.FromJson<MabaUserSettings>(json).Clamped();
                return true;
            }
            catch (Exception)
            {
                settings = MabaUserSettings.Defaults;
                return false;
            }
        }

        /// <summary>Forgets the saved choices.</summary>
        public static void ClearSaved()
        {
            try { PlayerPrefs.DeleteKey(PrefsKey); } catch (Exception) { }
            if (Changed != null) Changed(MabaUserSettings.Defaults);
        }
    }
}