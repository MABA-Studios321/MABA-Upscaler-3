// MABA Upscaler - checks shared by the inspector and the Tools menu. Editor only.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maba3.Editor
{
    /// <summary>One finding of the setup check.</summary>
    public struct MabaFinding
    {
        public MessageType Level;
        public string Text;

        public MabaFinding(MessageType level, string text)
        {
            Level = level;
            Text = text;
        }
    }

    public static class MabaSetupCheck
    {
        /// <summary>True when the project renders with the Universal Render Pipeline.</summary>
        public static bool UsesUrp()
        {
            RenderPipelineAsset asset = GraphicsSettings.currentRenderPipeline;
            return asset != null && asset.GetType().Name.Contains("Universal");
        }

        /// <summary>Findings for one component. Returns an empty list when everything is fine.</summary>
        public static List<MabaFinding> Check(MabaUpscaler maba)
        {
            var list = new List<MabaFinding>();
            Camera cam = maba.GetComponent<Camera>();
            if (cam == null)
            {
                list.Add(new MabaFinding(MessageType.Error, "MABA Upscaler needs a Camera on the same GameObject."));
                return list;
            }

            if (!Application.isPlaying && cam.targetTexture != null)
            {
                list.Add(new MabaFinding(MessageType.Warning,
                    "This camera already renders into a Render Texture. MABA takes over camera.targetTexture while it runs " +
                    "(it renders the scene into its own texture and upscales that to the screen). Clear the Target Texture."));
            }

            if (cam.stereoTargetEye != StereoTargetEyeMask.None)
            {
                list.Add(new MabaFinding(MessageType.Warning,
                    "Stereo / XR rendering is not handled by MABA (single view only)."));
            }

            if (PlayerSettings.colorSpace == ColorSpace.Linear)
            {
                list.Add(new MabaFinding(MessageType.Info,
                    "Colour space is Linear: the sharpening and dark-fade thresholds act on linear values. It works; " +
                    "tune Sharpness by eye (a Gamma project matches the reference exactly)."));
            }

            if (maba.temporal)
            {
                if (cam.orthographic)
                {
                    list.Add(new MabaFinding(MessageType.Info,
                        "Orthographic camera: the temporal tier jitters it through the projection's translation column. " +
                        "Check the result on your target device."));
                }
                if (cam.allowMSAA && QualitySettings.antiAliasing > 0)
                {
                    list.Add(new MabaFinding(MessageType.Info,
                        "MSAA is on. It works with the temporal tier, but you pay for both; the temporal tier already anti-aliases."));
                }
                if (maba.minScale > 0.999f)
                {
                    list.Add(new MabaFinding(MessageType.Info,
                        "Min Scale is 1.0, so the camera always renders at native size; the temporal tier then only anti-aliases."));
                }
            }

            if (maba.mode == MabaUpscaler.Mode.Dynamic && maba.targetFps < 20f)
            {
                list.Add(new MabaFinding(MessageType.Warning, "Target FPS is very low; Dynamic mode will rarely lower the render scale."));
            }

            if (Application.isPlaying && maba.temporal && !maba.TemporalRunning && !maba.IsNative)
            {
                list.Add(new MabaFinding(MessageType.Warning,
                    "Temporal is on but not running. Check the Console for a missing shader or an unsupported device " +
                    "(it needs the depth copy shader and a depth texture)."));
            }
            return list;
        }

        /// <summary>Project-level findings (no component needed).</summary>
        public static List<MabaFinding> CheckProject()
        {
            var list = new List<MabaFinding>();
            if (UsesUrp())
            {
                list.Add(new MabaFinding(MessageType.Info,
                    "Render pipeline: Universal (URP). The temporal tier switches the camera's Depth Texture on for you. " +
                    "Keep Screen Space - Overlay UI (or an overlay camera) so the UI is never upscaled."));
            }
            else if (GraphicsSettings.currentRenderPipeline == null)
            {
                list.Add(new MabaFinding(MessageType.Info,
                    "Render pipeline: Built-in. The upscale runs in OnPostRender; keep UI in Screen Space - Overlay mode."));
            }
            else
            {
                list.Add(new MabaFinding(MessageType.Warning,
                    "A scriptable render pipeline other than URP is active (" + GraphicsSettings.currentRenderPipeline.GetType().Name +
                    "). MABA hooks RenderPipelineManager.endCameraRendering, which works in principle, but only URP and the " +
                    "Built-in pipeline have been considered."));
            }
            return list;
        }

        /// <summary>The cameras in the open scenes that have no MabaUpscaler.</summary>
        public static List<Camera> CamerasWithout()
        {
            var cams = new List<Camera>();
            foreach (Camera c in Object.FindObjectsOfType<Camera>())
            {
                if (c.GetComponent<MabaUpscaler>() == null && c.cameraType == CameraType.Game) cams.Add(c);
            }
            return cams;
        }

        public static string Format(IEnumerable<MabaFinding> findings)
        {
            var sb = new System.Text.StringBuilder();
            foreach (MabaFinding f in findings)
            {
                string tag = f.Level == MessageType.Error ? "[ERROR]   " : f.Level == MessageType.Warning ? "[WARNING] " : "[ok]      ";
                sb.Append(tag).Append(f.Text).Append("\n\n");
            }
            return sb.ToString().TrimEnd();
        }
    }
}
