// The members of UnityEditor that the package's Editor scripts use, declared by hand (the editor assemblies are not available without
// installing Unity). This catches syntax and type mistakes in our own code; it cannot prove the real UnityEditor signatures.
using System;
using UnityEngine;
using UnityEngine.Rendering;
namespace UnityEditor
{
    public class MenuItem : Attribute { public MenuItem(string p) {} public MenuItem(string p, bool v) {} public MenuItem(string p, bool v, int prio) {} }
    public class CustomEditor : Attribute { public CustomEditor(Type t) {} }
    public class CanEditMultipleObjects : Attribute { }
    public static class EditorUtility { public static bool DisplayDialog(string a, string b, string c) { return true; } public static void SetDirty(UnityEngine.Object o) {} }
    public static class EditorGUIUtility { public static void PingObject(UnityEngine.Object o) {} }
    public static class Selection { public static GameObject[] gameObjects; public static GameObject activeGameObject; public static UnityEngine.Object activeObject; }
    public static class Undo { public static T AddComponent<T>(GameObject g) where T : Component { return null; } public static void RegisterCreatedObjectUndo(UnityEngine.Object o, string n) {} public static void RecordObject(UnityEngine.Object o, string n) {} }
    public static class AssetDatabase { public static T LoadAssetAtPath<T>(string p) where T : UnityEngine.Object { return null; } public static bool OpenAsset(UnityEngine.Object o) { return true; } }
    public static class PlayerSettings { public static ColorSpace colorSpace; }
    public class SerializedProperty { public bool hasMultipleDifferentValues; public int enumValueIndex; public int intValue; public float floatValue; public bool boolValue; }
    public class SerializedObject { public SerializedProperty FindProperty(string n) { return null; } public void Update() {} public bool ApplyModifiedProperties() { return true; } }
    public class Editor : ScriptableObject { public SerializedObject serializedObject; public UnityEngine.Object[] targets; public UnityEngine.Object target; public virtual void OnInspectorGUI() {} public virtual bool RequiresConstantRepaint() { return false; } }
    public enum MessageType { None, Info, Warning, Error }
    public static class EditorGUILayout
    {
        public static void PropertyField(SerializedProperty p) {} public static void PropertyField(SerializedProperty p, GUIContent c) {} public static void Space() {}
        public static bool BeginFoldoutHeaderGroup(bool f, string t) { return f; } public static void EndFoldoutHeaderGroup() {}
        public static void HelpBox(string m, MessageType t) {} public static void LabelField(string a) {} public static void LabelField(string a, string b) {} public static void LabelField(string a, GUIStyle s) {} public static void LabelField(string a, params GUILayoutOption[] o) {} public static void LabelField(string a, string b, GUIStyle s) {} public static void PrefixLabel(GUIContent c) {} public static void MinMaxSlider(ref float a, ref float b, float lo, float hi, params GUILayoutOption[] o) {} public class HorizontalScope : IDisposable { public HorizontalScope(params GUILayoutOption[] o) {} public void Dispose() {} }
    }
    public static class EditorStyles { public static GUIStyle boldLabel, miniButton, helpBox, foldoutHeader; }
    public static class EditorGUI { public static void BeginChangeCheck() {} public static bool EndChangeCheck() { return false; } public class DisabledScope : IDisposable { public DisabledScope(bool d) {} public void Dispose() {} } public class ChangeCheckScope : IDisposable { public bool changed; public void Dispose() {} } }
    public static class SessionState { }
}