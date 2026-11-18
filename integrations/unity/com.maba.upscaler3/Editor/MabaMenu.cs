// MABA Upscaler - Tools > MABA Upscaler menu. Editor only.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

namespace Maba3.Editor
{
    public static class MabaMenu
    {
        const string Root = "Tools/MABA Upscaler/";

        // ---- Setup -----------------------------------------------------------------------------

        [MenuItem(Root + "Add to Main Camera", false, 10)]
        static void AddToMainCamera()
        {
            Camera cam = Camera.main;
            if (cam == null)
            {
                EditorUtility.DisplayDialog("MABA Upscaler",
                    "No camera tagged MainCamera in the open scene. Select a camera and use \"Add to Selected Camera\".", "OK");
                return;
            }
            Add(cam);
        }

        [MenuItem(Root + "Add to Selected Camera", false, 11)]
        static void AddToSelectedCamera()
        {
            foreach (GameObject go in Selection.gameObjects)
            {
                Camera cam = go.GetComponent<Camera>();
                if (cam != null) Add(cam);
            }
        }

        [MenuItem(Root + "Add to Selected Camera", true)]
        static bool ValidateAddToSelectedCamera()
        {
            foreach (GameObject go in Selection.gameObjects)
            {
                if (go.GetComponent<Camera>() != null) return true;
            }
            return false;
        }

        static void Add(Camera cam)
        {
            if (cam.GetComponent<MabaUpscaler>() != null)
            {
                Selection.activeGameObject = cam.gameObject;
                EditorGUIUtility.PingObject(cam.gameObject);
                return;
            }
            MabaUpscaler added = Undo.AddComponent<MabaUpscaler>(cam.gameObject);
            Selection.activeObject = added;
            EditorGUIUtility.PingObject(cam.gameObject);
        }

        // ---- Presets for the selected cameras --------------------------------------------------

        [MenuItem(Root + "Add settings menu (quick, IMGUI)", false, 20)]
        static void AddSettingsMenu()
        {
            if (Object.FindObjectOfType<MabaSettingsMenu>() != null)
            {
                EditorUtility.DisplayDialog("MABA Upscaler 3", "This scene already has a MABA settings menu.", "OK");
                return;
            }
            var go = new GameObject("MABA Settings Menu");
            Undo.RegisterCreatedObjectUndo(go, "Add MABA settings menu");
            go.AddComponent<MabaSettingsMenu>();
            Selection.activeGameObject = go;
            EditorUtility.DisplayDialog("MABA Upscaler 3",
                "Added a settings menu. Press F10 in Play mode to show it (or set Visible). For a styled in-game menu, add a MabaSettingsBinder next to your own uGUI controls instead.", "OK");
        }

        [MenuItem(Root + "Preset/Dynamic", false, 30)]
        static void PresetDynamic() { SetPreset(MabaUpscaler.Mode.Dynamic); }
        [MenuItem(Root + "Preset/Ultra Quality (77%)", false, 31)]
        static void PresetUltra() { SetPreset(MabaUpscaler.Mode.UltraQuality); }
        [MenuItem(Root + "Preset/Quality (67%)", false, 32)]
        static void PresetQuality() { SetPreset(MabaUpscaler.Mode.Quality); }
        [MenuItem(Root + "Preset/Balanced (59%)", false, 33)]
        static void PresetBalanced() { SetPreset(MabaUpscaler.Mode.Balanced); }
        [MenuItem(Root + "Preset/Performance (50%)", false, 34)]
        static void PresetPerformance() { SetPreset(MabaUpscaler.Mode.Performance); }

        static void SetPreset(MabaUpscaler.Mode mode)
        {
            foreach (GameObject go in Selection.gameObjects)
            {
                MabaUpscaler maba = go.GetComponent<MabaUpscaler>();
                if (maba == null) continue;
                Undo.RecordObject(maba, "MABA preset");
                maba.mode = mode;
                EditorUtility.SetDirty(maba);
            }
        }

        // A MenuItem attribute cannot be repeated on one method, so each preset has its own validate method.
        static bool HasMaba()
        {
            foreach (GameObject go in Selection.gameObjects)
            {
                if (go.GetComponent<MabaUpscaler>() != null) return true;
            }
            return false;
        }

        [MenuItem(Root + "Preset/Dynamic", true)] static bool ValidateDynamic() { return HasMaba(); }
        [MenuItem(Root + "Preset/Ultra Quality (77%)", true)] static bool ValidateUltra() { return HasMaba(); }
        [MenuItem(Root + "Preset/Quality (67%)", true)] static bool ValidateQuality() { return HasMaba(); }
        [MenuItem(Root + "Preset/Balanced (59%)", true)] static bool ValidateBalanced() { return HasMaba(); }
        [MenuItem(Root + "Preset/Performance (50%)", true)] static bool ValidatePerformance() { return HasMaba(); }

        // ---- Checks and docs -------------------------------------------------------------------

        [MenuItem(Root + "Check Project Setup", false, 50)]
        public static void ShowProjectReport()
        {
            var all = new List<MabaFinding>(MabaSetupCheck.CheckProject());
            MabaUpscaler[] components = Object.FindObjectsOfType<MabaUpscaler>();
            foreach (MabaUpscaler m in components)
            {
                foreach (MabaFinding f in MabaSetupCheck.Check(m))
                {
                    all.Add(new MabaFinding(f.Level, m.name + ": " + f.Text));
                }
            }
            List<Camera> missing = MabaSetupCheck.CamerasWithout();
            if (components.Length == 0)
            {
                all.Add(new MabaFinding(MessageType.Warning, "No MABA Upscaler component in the open scenes. Use Tools > MABA Upscaler > Add to Main Camera."));
            }
            else if (missing.Count > 0)
            {
                all.Add(new MabaFinding(MessageType.Info, missing.Count + " other camera(s) have no MABA Upscaler. That is fine for overlay / UI cameras " +
                    "(attach MABA to the base camera only)."));
            }
            EditorUtility.DisplayDialog("MABA Upscaler: project check", MabaSetupCheck.Format(all), "OK");
        }

        [MenuItem(Root + "Open Documentation", false, 70)]
        static void OpenDocumentation()
        {
            TextAsset readme = AssetDatabase.LoadAssetAtPath<TextAsset>("Packages/com.maba.upscaler3/README.md");
            if (readme != null)
            {
                AssetDatabase.OpenAsset(readme);
            }
            else
            {
                EditorUtility.DisplayDialog("MABA Upscaler",
                    "README.md was not found in the package folder. It ships with the package (Packages/com.maba.upscaler3/README.md).", "OK");
            }
        }
    }
}
