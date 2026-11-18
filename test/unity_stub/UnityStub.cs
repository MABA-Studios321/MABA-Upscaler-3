// Minimal hand-written stand-ins for the UnityEngine API surface the MABA runtime uses. This only checks that
// the C# is syntactically and type-wise consistent; it is NOT Unity.
using System;
namespace UnityEngine
{
    public class Object { public string name; public HideFlags hideFlags; public static void Destroy(Object o) {} public static T FindObjectOfType<T>() where T : Object { return null; } public static implicit operator bool(Object o) { return o != null; } }
    public enum HideFlags { None, HideAndDontSave }
    public class Component : Object { public T GetComponent<T>() where T : class { return null; } public Component GetComponent(Type t) { return null; } public Transform transform; public GameObject gameObject; }
    public class Behaviour : Component { public bool enabled; }
    public class MonoBehaviour : Behaviour { }
    public class RequireComponent : Attribute { public RequireComponent(Type t) {} }
    public class DisallowMultipleComponent : Attribute { }
    public class AddComponentMenu : Attribute { public AddComponentMenu(string s) {} }
    public class HeaderAttribute : Attribute { public HeaderAttribute(string s) {} }
    public class TooltipAttribute : Attribute { public TooltipAttribute(string s) {} }
    public class RangeAttribute : Attribute { public RangeAttribute(float a, float b) {} }
    public struct Vector2 { public float x, y; public Vector2(float x, float y) { this.x = x; this.y = y; } }
    public struct Vector2Int { public int x, y; public Vector2Int(int x, int y) { this.x = x; this.y = y; } }
    public struct Vector4 { public float x, y, z, w; public Vector4(float x, float y, float z, float w) { this.x = x; this.y = y; this.z = z; this.w = w; } }
    public struct Rect { public Rect(float x, float y, float w, float h) {} }
    public struct Matrix4x4
    {
        public float this[int r, int c] { get { return 0; } set { } }
        public Matrix4x4 inverse { get { return this; } }
        public static Matrix4x4 operator *(Matrix4x4 a, Matrix4x4 b) { return a; }
    }
    public static class Mathf
    {
        public static float Clamp(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
        public static int Clamp(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }
        public static int Max(int a, int b) { return a > b ? a : b; }
        public static float Max(float a, float b) { return a > b ? a : b; }
        public static int Min(int a, int b) { return a < b ? a : b; }
        public static float Min(float a, float b) { return a < b ? a : b; }
        public static int RoundToInt(float f) { return (int)System.Math.Round(f, System.MidpointRounding.ToEven); }
        public static float Round(float f) { return (float)System.Math.Round(f, System.MidpointRounding.ToEven); }
        public static float Floor(float f) { return (float)System.Math.Floor(f); }
    }    public static class Debug { public static void Log(object o) {} public static void LogError(object o, Object c) {} public static void LogError(object o) {} public static void LogWarning(object o) {} }
    public static class Time { public static float unscaledDeltaTime; public static double unscaledTimeAsDouble; public static float deltaTime; }
    public static class Screen { public static int width, height; }
    public enum CameraClearFlags { Skybox, Color, Depth, Nothing }
    public enum DepthTextureMode { None = 0, Depth = 1, MotionVectors = 4 }
    public class Shader : Object { public bool isSupported; public static Shader Find(string n) { return null; } public static int PropertyToID(string n) { return 0; } public static Texture GetGlobalTexture(string n) { return null; } }
    public class Material : Object
    {
        public Material(Shader s) {}
        public void SetTexture(int id, Texture t) {} public void SetMatrix(int id, Matrix4x4 m) {}
        public void SetVector(int id, Vector4 v) {} public void SetFloat(int id, float f) {} public bool SetPass(int p) { return true; }
    }
    public class Resources { public static T Load<T>(string p) where T : Object { return null; } }
    public class Texture : Object { public int width, height; public FilterMode filterMode; public TextureWrapMode wrapMode; }
    public enum FilterMode { Point, Bilinear }
    public enum TextureWrapMode { Clamp, Repeat }
    public enum RenderTextureFormat { ARGB32, RFloat, RHalf, ARGBHalf }
    public enum RenderTextureReadWrite { Default, Linear }
    public struct RenderBuffer { }
    public class RenderTexture : Texture
    {
        public RenderTexture(int w, int h, int d, RenderTextureFormat f) {}
        public RenderTexture(int w, int h, int d, RenderTextureFormat f, RenderTextureReadWrite rw) {}
        public bool useMipMap; public RenderBuffer colorBuffer; public RenderBuffer depthBuffer;
        public void Create() {} public void Release() {}
    }
    public static class SystemInfo
    {
        public static int graphicsShaderLevel; public static bool usesReversedZBuffer; public static UnityEngine.Rendering.GraphicsDeviceType graphicsDeviceType; public static int supportedRenderTargetCount;
        public static bool SupportsRenderTextureFormat(RenderTextureFormat f) { return true; }
    }
    public enum MeshTopology { Triangles }
    public static class Graphics
    {
        public static void SetRenderTarget(RenderTexture rt) {}
        public static void SetRenderTarget(RenderBuffer[] colors, RenderBuffer depth) {}
        public static void DrawProceduralNow(MeshTopology t, int n) {}
    }
    public static class GL { public static void Viewport(Rect r) {} }
    public struct FrameTiming { public double gpuFrameTime; }
    public static class FrameTimingManager { public static void CaptureFrameTimings() {} public static uint GetLatestTimings(uint n, FrameTiming[] t) { return 0; } }
    public class Camera : Behaviour
    {
        public Rect rect; public Rect pixelRect; public RenderTexture targetTexture; public DepthTextureMode depthTextureMode;
        public Matrix4x4 projectionMatrix; public Matrix4x4 worldToCameraMatrix; public bool orthographic;
        public float nearClipPlane, farClipPlane; public int cullingMask; public CameraClearFlags clearFlags; public float depth; public bool allowMSAA, useOcclusionCulling;
        public void ResetProjectionMatrix() {}
    }
    public static partial class GUI { public static void Label(Rect r, string s) {} }
}
namespace UnityEngine.Rendering
{
    public struct ScriptableRenderContext { }
    public enum GraphicsDeviceType { Null, OpenGLES3, Vulkan }
    public static class GraphicsSettings { public static object currentRenderPipeline; }
    public static class RenderPipelineManager { public static event Action<ScriptableRenderContext, UnityEngine.Camera> endCameraRendering; }
}


namespace UnityEngine
{
    public enum KeyCode { None, F10 }
    public static class Input { public static bool GetKeyDown(KeyCode k) { return false; } }
    public static class PlayerPrefs
    {
        public static bool HasKey(string k) { return false; } public static string GetString(string k) { return ""; }
        public static void SetString(string k, string v) {} public static void Save() {} public static void DeleteKey(string k) {}
    }
    public static class JsonUtility { public static string ToJson(object o) { return ""; } public static T FromJson<T>(string s) { return default(T); } }
    public static partial class GUI { public static bool enabled; public static void Box(Rect r, string s) {} }
    public static class GUILayout
    {
        public static void BeginArea(Rect r) {} public static void EndArea() {}
        public static void BeginVertical(string style) {} public static void EndVertical() {}
        public static void Label(string s) {}
        public static int SelectionGrid(int selected, string[] names, int columns) { return selected; }
        public static float HorizontalSlider(float v, float a, float b) { return v; }
        public static bool Toggle(bool v, string s) { return v; }
    }
    public class GameObject : Object
    {
        public GameObject(string name) {} public Transform transform;
        public T AddComponent<T>() where T : Component, new() { return new T(); } public Component AddComponent(Type t) { return null; }
        public void SetActive(bool b) {}
    }
    public class Transform : Component { public void SetParent(Transform t, bool worldPositionStays) {} }
    public static class ObjectExt { }
}
namespace UnityEngine.Events
{
    public delegate void UnityAction<T>(T arg);
    public class UnityEvent<T> { public void AddListener(UnityAction<T> a) {} public void RemoveListener(UnityAction<T> a) {} }
}
namespace UnityEngine.UI
{
    using System.Collections.Generic;
    public class Selectable : Behaviour { public bool interactable; }
    public class Dropdown : Selectable
    {
        public int value;
        public UnityEngine.Events.UnityEvent<int> onValueChanged = new UnityEngine.Events.UnityEvent<int>();
        public void ClearOptions() {} public void AddOptions(List<string> o) {} public void SetValueWithoutNotify(int v) {} public void RefreshShownValue() {}
    }
    public class Slider : Selectable
    {
        public float minValue, maxValue, value; public bool wholeNumbers;
        public UnityEngine.Events.UnityEvent<float> onValueChanged = new UnityEngine.Events.UnityEvent<float>();
        public void SetValueWithoutNotify(float v) {}
    }
    public class Toggle : Selectable
    {
        public bool isOn;
        public UnityEngine.Events.UnityEvent<bool> onValueChanged = new UnityEngine.Events.UnityEvent<bool>();
        public void SetIsOnWithoutNotify(bool v) {}
    }
    public class Text : Behaviour { public string text; }
}