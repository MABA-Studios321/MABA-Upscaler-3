// MABA Upscaler 3 - a quick drop-in settings menu with no Canvas to set up (IMGUI): preset, sharpness, Frame Generation and a
// status line. Add it to any GameObject (menu: Tools > MABA Upscaler > Add settings menu), press F10 (or set `visible`) and
// it controls the first MabaUpscaler in the scene and saves the player's choices. For a polished in-game menu use the
// MabaSettingsBinder with your own uGUI controls, or build on the MabaSettings API.
//
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using UnityEngine;

namespace Maba3
{
    [AddComponentMenu("MABA/MABA Settings Menu (quick)")]
    public sealed class MabaSettingsMenu : MonoBehaviour
    {
        [Tooltip("The upscaler to control. Empty = the first MabaUpscaler in the scene.")]
        public MabaUpscaler target;
        [Tooltip("Show the menu now.")]
        public bool visible = false;
        [Tooltip("Press to show / hide the menu (needs the legacy Input Manager; with the Input System package set `visible` from your own code).")]
        public KeyCode toggleKey = KeyCode.F10;
        [Tooltip("Save every change with MabaSettings.Save.")]
        public bool autoSave = true;
        public Vector2 position = new Vector2(16f, 16f);
        public float width = 360f;

        static readonly string[] FrameGenerationNames = { "Off", "2x", "3x" };
        string[] presetNames;

        void Update()
        {
#if ENABLE_LEGACY_INPUT_MANAGER
            if (Input.GetKeyDown(toggleKey)) visible = !visible;
#endif
        }

        void OnGUI()
        {
            if (!visible) return;
            if (target == null) target = FindObjectOfType<MabaUpscaler>();
            GUILayout.BeginArea(new Rect(position.x, position.y, width, 420f));
            GUILayout.BeginVertical("box");
            GUILayout.Label("MABA Upscaler 3");
            if (target == null)
            {
                GUILayout.Label("No MabaUpscaler component in the scene.");
                GUILayout.EndVertical();
                GUILayout.EndArea();
                return;
            }
            if (presetNames == null)
            {
                var infos = MabaSettings.GetModeInfos(new Vector2Int(Screen.width, Screen.height));
                presetNames = new string[infos.Length];
                for (int i = 0; i < infos.Length; i++)
                    presetNames[i] = infos[i].fixedScale ? string.Format("{0} {1}%", infos[i].name, Mathf.RoundToInt(infos[i].scale * 100f)) : infos[i].name;
            }
            MabaUserSettings s = target.GetSettings();
            MabaUserSettings before = s;

            GUILayout.Label("Quality preset");
            s.mode = (MabaUpscaler.Mode)GUILayout.SelectionGrid((int)s.mode, presetNames, 2);
            GUILayout.Label(string.Format("Sharpness {0:0.00}", s.sharpness));
            s.sharpness = GUILayout.HorizontalSlider(s.sharpness, 0f, 1f);
            if (s.mode == MabaUpscaler.Mode.Dynamic)
            {
                GUILayout.Label(string.Format("Target frame rate {0:0} fps", s.targetFps));
                s.targetFps = Mathf.Round(GUILayout.HorizontalSlider(s.targetFps, 15f, 240f));
            }
            GUILayout.Label("Frame Generation");
            bool fgOk = MabaSettings.IsFrameGenerationSupported();
            GUI.enabled = fgOk;
            s.frameGeneration = (FrameGeneration)GUILayout.SelectionGrid((int)s.frameGeneration, FrameGenerationNames, 3);
            s.frameGenerationAutoPause = GUILayout.Toggle(s.frameGenerationAutoPause, "Pause automatically when it would not help");
            GUI.enabled = true;
            if (!fgOk) GUILayout.Label("Frame Generation is not available on this device.");

            string status = string.Format("{0} | render {1}x{2} | {3:0} fps", target.mode, target.RenderSize.x, target.RenderSize.y, target.CurrentFps);
            if (target.frameGeneration != FrameGeneration.Off)
                status += " | Frame Generation " + (target.FrameGenerationPaused ? "paused" : (target.FrameGenerationActive ? "on" : "ready"));
            GUILayout.Label(status);
            GUILayout.EndVertical();
            GUILayout.EndArea();

            if (!s.Equals(before))
            {
                target.Apply(s);
                if (autoSave) MabaSettings.Save(target.GetSettings());
            }
        }
    }
}