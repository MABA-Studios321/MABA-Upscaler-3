// MABA Upscaler 3 - binds your own uGUI controls to the upscaler settings. Build the menu in your own style, drop the
// controls into the fields below (leave any you do not need empty) and this component fills the dropdowns, keeps every
// control in step with the settings, applies what the player changes and saves it (MabaSettings.Save).
// Works with UnityEngine.UI (Dropdown, Slider, Toggle, Text). For TextMeshPro or UI Toolkit use the MabaSettings API directly.
//
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

namespace Maba3
{
    [AddComponentMenu("MABA/MABA Settings Binder (uGUI)")]
    public sealed class MabaSettingsBinder : MonoBehaviour
    {
        [Tooltip("The upscaler to control. Empty = the first MabaUpscaler in the scene.")]
        public MabaUpscaler target;
        [Tooltip("Quality preset. Options are filled in for you: \"Balanced (59% render)\" ...")]
        public Dropdown presetDropdown;
        [Tooltip("0..1 sharpening.")]
        public Slider sharpnessSlider;
        [Tooltip("Dynamic preset: the frame rate it holds (the slider's range is set to 15..240, whole numbers).")]
        public Slider targetFpsSlider;
        [Tooltip("Off / 2x / 3x. Options are filled in for you. Disabled where Frame Generation cannot run.")]
        public Dropdown frameGenerationDropdown;
        [Tooltip("Pause Frame Generation when it would not help.")]
        public Toggle autoPauseToggle;
        [Tooltip("A live one-line status (render size, fps, Frame Generation state).")]
        public Text statusText;
        [Tooltip("Show the target-fps slider only while the Dynamic preset is chosen (this object is enabled/disabled).")]
        public GameObject dynamicOnlyGroup;
        [Tooltip("Save every change with MabaSettings.Save so it comes back next time.")]
        public bool autoSave = true;

        bool updating;
        float statusTimer;

        void OnEnable()
        {
            if (target == null) target = FindObjectOfType<MabaUpscaler>();
            if (presetDropdown != null)
            {
                presetDropdown.ClearOptions();
                var names = new List<string>();
                foreach (MabaModeInfo info in MabaSettings.GetModeInfos(new Vector2Int(Screen.width, Screen.height)))
                    names.Add(info.fixedScale ? string.Format("{0} ({1}% render)", info.name, Mathf.RoundToInt(info.scale * 100f)) : info.name + " (follows the target fps)");
                presetDropdown.AddOptions(names);
                presetDropdown.onValueChanged.AddListener(OnPreset);
            }
            if (sharpnessSlider != null)
            {
                sharpnessSlider.minValue = 0f; sharpnessSlider.maxValue = 1f; sharpnessSlider.wholeNumbers = false;
                sharpnessSlider.onValueChanged.AddListener(OnSharpness);
            }
            if (targetFpsSlider != null)
            {
                targetFpsSlider.minValue = 15f; targetFpsSlider.maxValue = 240f; targetFpsSlider.wholeNumbers = true;
                targetFpsSlider.onValueChanged.AddListener(OnTargetFps);
            }
            if (frameGenerationDropdown != null)
            {
                frameGenerationDropdown.ClearOptions();
                frameGenerationDropdown.AddOptions(new List<string> { "Off", "2x", "3x" });
                frameGenerationDropdown.interactable = MabaSettings.IsFrameGenerationSupported();
                frameGenerationDropdown.onValueChanged.AddListener(OnFrameGeneration);
            }
            if (autoPauseToggle != null) autoPauseToggle.onValueChanged.AddListener(OnAutoPause);
            MabaSettings.Changed += OnSettingsChanged;
            Refresh();
        }

        void OnDisable()
        {
            MabaSettings.Changed -= OnSettingsChanged;
            if (presetDropdown != null) presetDropdown.onValueChanged.RemoveListener(OnPreset);
            if (sharpnessSlider != null) sharpnessSlider.onValueChanged.RemoveListener(OnSharpness);
            if (targetFpsSlider != null) targetFpsSlider.onValueChanged.RemoveListener(OnTargetFps);
            if (frameGenerationDropdown != null) frameGenerationDropdown.onValueChanged.RemoveListener(OnFrameGeneration);
            if (autoPauseToggle != null) autoPauseToggle.onValueChanged.RemoveListener(OnAutoPause);
        }

        void Update()
        {
            if (statusText == null || target == null) return;
            statusTimer -= Time.unscaledDeltaTime;
            if (statusTimer > 0f) return;
            statusTimer = 0.4f;
            string text = string.Format("{0} | render {1}x{2} | {3:0} fps", target.mode, target.RenderSize.x, target.RenderSize.y, target.CurrentFps);
            if (target.frameGeneration != FrameGeneration.Off)
                text += " | Frame Generation " + target.frameGeneration + (target.FrameGenerationPaused ? ": paused (it would not help)" : (target.FrameGenerationActive ? ": on" : ": ready"));
            statusText.text = text;
        }

        void OnSettingsChanged(MabaUserSettings s) { Refresh(); }

        /// <summary>Shows the upscaler's current settings in the controls.</summary>
        public void Refresh()
        {
            if (target == null) return;
            MabaUserSettings s = target.GetSettings();
            updating = true;
            if (presetDropdown != null) { presetDropdown.SetValueWithoutNotify((int)s.mode); presetDropdown.RefreshShownValue(); }
            if (sharpnessSlider != null) sharpnessSlider.SetValueWithoutNotify(s.sharpness);
            if (targetFpsSlider != null) targetFpsSlider.SetValueWithoutNotify(s.targetFps);
            if (frameGenerationDropdown != null) { frameGenerationDropdown.SetValueWithoutNotify((int)s.frameGeneration); frameGenerationDropdown.RefreshShownValue(); }
            if (autoPauseToggle != null) autoPauseToggle.SetIsOnWithoutNotify(s.frameGenerationAutoPause);
            if (dynamicOnlyGroup != null) dynamicOnlyGroup.SetActive(s.mode == MabaUpscaler.Mode.Dynamic);
            updating = false;
        }

        void Commit(MabaUserSettings s)
        {
            if (target == null) return;
            target.Apply(s);
            if (autoSave) MabaSettings.Save(target.GetSettings());
            else Refresh();
        }

        void OnPreset(int index)
        {
            if (updating || target == null) return;
            MabaUserSettings s = target.GetSettings();
            s.mode = (MabaUpscaler.Mode)index;
            Commit(s);
        }

        void OnSharpness(float v)
        {
            if (updating || target == null) return;
            MabaUserSettings s = target.GetSettings();
            s.sharpness = v;
            Commit(s);
        }

        void OnTargetFps(float v)
        {
            if (updating || target == null) return;
            MabaUserSettings s = target.GetSettings();
            s.targetFps = v;
            Commit(s);
        }

        void OnFrameGeneration(int index)
        {
            if (updating || target == null) return;
            MabaUserSettings s = target.GetSettings();
            s.frameGeneration = (FrameGeneration)index;
            Commit(s);
        }

        void OnAutoPause(bool on)
        {
            if (updating || target == null) return;
            MabaUserSettings s = target.GetSettings();
            s.frameGenerationAutoPause = on;
            Commit(s);
        }
    }
}