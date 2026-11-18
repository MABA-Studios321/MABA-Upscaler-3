// MABA Upscaler - custom inspector: preset buttons, grouped settings, live status, setup warnings.
// Editor only. Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using UnityEditor;
using UnityEngine;

namespace Maba3.Editor
{
    [CustomEditor(typeof(MabaUpscaler))]
    [CanEditMultipleObjects]
    public sealed class MabaUpscalerInspector : UnityEditor.Editor
    {
        static readonly string[] ModeNames = { "Dynamic", "Ultra Quality", "Quality", "Balanced", "Performance" };
        static readonly string[] ModeHints =
        {
            "Holds the target frame rate by moving the render scale between Min and Max in 1% steps.",
            "Fixed 77% render scale: closest to native.",
            "Fixed 67% render scale.",
            "Fixed 59% render scale with the quality kernel: a good default for weak GPUs.",
            "Fixed 50% render scale with the fast kernel: the most frame rate.",
        };

        SerializedProperty mode, sharpness, targetFps, minScale, maxScale;
        SerializedProperty temporal, clipGamma, depthTolerance, debugOverlay, frameGeneration, frameGenerationAutoPause, useSavedSettings;

        // Foldout state survives the inspector being rebuilt.
        static bool showDynamic = true, showTemporal = true, showStatus = true, showChecks = true;

        void OnEnable()
        {
            mode = serializedObject.FindProperty("mode");
            sharpness = serializedObject.FindProperty("sharpness");
            targetFps = serializedObject.FindProperty("targetFps");
            minScale = serializedObject.FindProperty("minScale");
            maxScale = serializedObject.FindProperty("maxScale");
            temporal = serializedObject.FindProperty("temporal");
            clipGamma = serializedObject.FindProperty("clipGamma");
            depthTolerance = serializedObject.FindProperty("depthTolerance");
            debugOverlay = serializedObject.FindProperty("debugOverlay");
            frameGeneration = serializedObject.FindProperty("frameGeneration");
            frameGenerationAutoPause = serializedObject.FindProperty("frameGenerationAutoPause");
            useSavedSettings = serializedObject.FindProperty("useSavedSettings");
        }

        // The live status block changes every frame while playing.
        public override bool RequiresConstantRepaint()
        {
            return Application.isPlaying;
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();

            DrawPresets();
            EditorGUILayout.PropertyField(sharpness);
            EditorGUILayout.Space();

            bool dynamic = !mode.hasMultipleDifferentValues && mode.enumValueIndex == 0;
            showDynamic = EditorGUILayout.BeginFoldoutHeaderGroup(showDynamic, "Dynamic mode");
            if (showDynamic)
            {
                using (new EditorGUI.DisabledScope(!dynamic && !mode.hasMultipleDifferentValues))
                {
                    EditorGUILayout.PropertyField(targetFps);
                    DrawScaleRange();
                }
                if (!dynamic && !mode.hasMultipleDifferentValues)
                {
                    EditorGUILayout.HelpBox("The fixed presets ignore these settings. Switch to Dynamic to use them.", MessageType.None);
                }
            }
            EditorGUILayout.EndFoldoutHeaderGroup();

            showTemporal = EditorGUILayout.BeginFoldoutHeaderGroup(showTemporal, "Temporal super-resolution (MABA Upscaler 3)");
            if (showTemporal)
            {
                EditorGUILayout.PropertyField(temporal, new GUIContent("Temporal",
                    "Jittered render with accumulation at output resolution: more detail and stability than a spatial upscale, for a few ms on a low-end phone. Needs a depth texture."));
                using (new EditorGUI.DisabledScope(!temporal.boolValue && !temporal.hasMultipleDifferentValues))
                {
                    EditorGUILayout.PropertyField(clipGamma);
                    EditorGUILayout.PropertyField(depthTolerance);
                    if (GUILayout.Button("Reset tuning to defaults"))
                    {
                        clipGamma.floatValue = 1.25f;
                        depthTolerance.floatValue = 0.01f;
                    }
                }
            }
            EditorGUILayout.EndFoldoutHeaderGroup();

            EditorGUILayout.LabelField("Frame Generation", EditorStyles.boldLabel);
            EditorGUILayout.PropertyField(frameGeneration);
            using (new EditorGUI.DisabledScope(frameGeneration.enumValueIndex == 0 && !frameGeneration.hasMultipleDifferentValues))
            {
                EditorGUILayout.PropertyField(frameGenerationAutoPause);
            }
            if (frameGeneration.enumValueIndex != 0 && !Maba3.MabaSettings.IsFrameGenerationSupported())
            {
                EditorGUILayout.HelpBox("Frame Generation needs temporal super-resolution (ES 3.1 / SM 4.5 class hardware) and multiple render targets: not available on the current graphics API.", MessageType.Warning);
            }
            else if (frameGeneration.enumValueIndex != 0)
            {
                EditorGUILayout.HelpBox("Frame Generation switches this camera off on generated frames and presents a re-projection of the last rendered one. Use Screen Space - Overlay UI. Objects that move by themselves update on rendered frames only.", MessageType.Info);
            }
            EditorGUILayout.PropertyField(useSavedSettings);
            EditorGUILayout.Space();
            EditorGUILayout.PropertyField(debugOverlay);
            serializedObject.ApplyModifiedProperties();

            if (targets.Length == 1)
            {
                var maba = (MabaUpscaler)target;
                DrawStatus(maba);
                DrawChecks(maba);
            }
        }

        void DrawPresets()
        {
            EditorGUILayout.LabelField("Preset", EditorStyles.boldLabel);
            using (new EditorGUILayout.HorizontalScope())
            {
                for (int i = 0; i < ModeNames.Length; i++)
                {
                    bool selected = !mode.hasMultipleDifferentValues && mode.enumValueIndex == i;
                    bool pressed = GUILayout.Toggle(selected, ModeNames[i], EditorStyles.miniButton);
                    if (pressed && !selected) mode.enumValueIndex = i;
                }
            }
            if (!mode.hasMultipleDifferentValues && mode.enumValueIndex >= 0 && mode.enumValueIndex < ModeHints.Length)
            {
                EditorGUILayout.HelpBox(ModeHints[mode.enumValueIndex], MessageType.None);
            }
        }

        // Min and Max as one range slider, written back to the two serialized floats.
        void DrawScaleRange()
        {
            float lo = minScale.floatValue, hi = maxScale.floatValue;
            EditorGUI.BeginChangeCheck();
            using (new EditorGUILayout.HorizontalScope())
            {
                EditorGUILayout.PrefixLabel(new GUIContent("Scale range",
                    "Dynamic mode never renders below Min or above Max (as a fraction of the screen). Max 1.0 = native, no upscale pass. " +
                    "A lower Max also allocates a smaller render texture."));
                EditorGUILayout.LabelField(lo.ToString("0.00"), GUILayout.Width(34));
                EditorGUILayout.MinMaxSlider(ref lo, ref hi, 0.35f, 1f);
                EditorGUILayout.LabelField(hi.ToString("0.00"), GUILayout.Width(34));
            }
            if (EditorGUI.EndChangeCheck())
            {
                minScale.floatValue = Mathf.Round(lo * 100f) / 100f;
                maxScale.floatValue = Mathf.Round(hi * 100f) / 100f;
            }
        }

        void DrawStatus(MabaUpscaler maba)
        {
            showStatus = EditorGUILayout.BeginFoldoutHeaderGroup(showStatus, "Status");
            if (showStatus)
            {
                if (!Application.isPlaying)
                {
                    EditorGUILayout.HelpBox("Enter Play mode to see the live render scale, frame rate and temporal state.", MessageType.None);
                }
                else
                {
                    Vector2Int size = maba.RenderSize;
                    EditorGUILayout.LabelField("Render scale", (maba.RenderScale * 100f).ToString("0") + "%   (" + size.x + " x " + size.y + ")");
                    EditorGUILayout.LabelField("Kernel", maba.IsNative ? "native (no upscale pass)" : (maba.QualityKernel ? "quality (12-tap)" : "fast"));
                    EditorGUILayout.LabelField("Frame rate", maba.CurrentFps.ToString("0") + " fps" + (maba.GpuMs > 0f ? "   GPU " + maba.GpuMs.ToString("0.0") + " ms" : ""));
                    EditorGUILayout.LabelField("Temporal", maba.temporal ? (maba.TemporalRunning ? "running" : "requested, not running") : "off");
                    using (new EditorGUI.DisabledScope(!maba.temporal))
                    {
                        if (GUILayout.Button("Reset temporal history")) maba.ResetHistory();
                    }
                }
            }
            EditorGUILayout.EndFoldoutHeaderGroup();
        }

        void DrawChecks(MabaUpscaler maba)
        {
            var findings = MabaSetupCheck.Check(maba);
            if (findings.Count == 0) return;
            showChecks = EditorGUILayout.BeginFoldoutHeaderGroup(showChecks, "Setup check (" + findings.Count + ")");
            if (showChecks)
            {
                foreach (MabaFinding f in findings) EditorGUILayout.HelpBox(f.Text, f.Level);
                if (GUILayout.Button("Check whole project...")) MabaMenu.ShowProjectReport();
            }
            EditorGUILayout.EndFoldoutHeaderGroup();
        }
    }
}
