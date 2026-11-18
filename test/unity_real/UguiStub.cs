// uGUI (com.unity.ugui) is a package, not part of the engine assemblies, so these few members are declared here as Unity documents them.
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