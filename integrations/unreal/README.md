# MABA Upscaler 3 for Unreal Engine

Two plugins, one per engine generation. They share every source file except one small compatibility header, so a fix lands in both.

| Folder | Engine | State |
|---|---|---|
| [`UE5/MabaUpscaler3`](UE5/MabaUpscaler3) | Unreal Engine 5.0 - 5.8 | compiled and run in a game on **5.6 and 5.8** (Blueprint API, settings menu, upscaler, Frame Generation); 5.0 - 5.5 not compiled |
| [`UE4/MabaUpscaler3`](UE4/MabaUpscaler3) | Unreal Engine 4.26 - 4.27 | **never compiled** (no UE4 engine was available); the UE5 plugin with the UE4 differences written from the API history |

Copy exactly one `MabaUpscaler3` folder into your project's `Plugins/` directory, the one that matches your engine. Each has its own
README with install steps, the API, and an honest list of what was and was not tested.

Both plugins are Windows-only so far.