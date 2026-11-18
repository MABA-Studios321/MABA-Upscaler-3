# Behaviour tests (run in game by run_unreal_fg_test.ps1): settings API round trip, the settings menu, the 3x pattern and the governor.
# Prints MABATEST lines; the PowerShell side turns them into PASS / FAIL.
# Order matters: the API checks run first because a console command (priority SetByConsole) outranks the API's code-priority writes
# by design, so after a console `r.Maba.Mode 3` the API could not change the mode any more.
import unreal
st = {"f": 0, "phase": "api", "seq": "", "paused_at": None, "gov_start": 0}
def w(): return unreal.find_object(None, "/Game/TestMap.TestMap")
def cmd(c): unreal.SystemLibrary.execute_console_command(w(), c)
def log(m): unreal.log("MABATEST " + m)
def status(): return unreal.MabaBlueprintLibrary.get_maba_status()
def tick(dt):
    try: tick2(dt)
    except Exception as e:
        log("EXC " + repr(e)); cmd("quit")
def tick2(dt):
    st["f"] += 1
    f = st["f"]
    if st["phase"] == "api":
        if f < 20: return
        lib = unreal.MabaBlueprintLibrary
        infos = lib.get_maba_mode_infos(unreal.IntPoint(1920, 1080))
        sizes = [(i.render_size.x, i.render_size.y) for i in infos]
        log("mode sizes %s -> %s" % (sizes, "PASS" if (1133, 637) in sizes and (960, 540) in sizes else "FAIL"))
        rec = (lib.get_maba_recommended_mode(unreal.IntPoint(3840, 2160)), lib.get_maba_recommended_mode(unreal.IntPoint(1280, 720)))
        log("recommended 4K / 720p %s -> %s" % (rec, "PASS" if rec == (unreal.MabaMode.PERFORMANCE, unreal.MabaMode.ULTRA_QUALITY) else "FAIL"))
        log("frame generation supported -> %s" % ("PASS" if lib.is_maba_frame_generation_supported() else "FAIL"))
        sub = lib.get_maba_subsystem(w())
        s = sub.get_user_settings()
        s.mode = unreal.MabaMode.QUALITY; s.sharpness = 0.35; s.frame_generation = unreal.MabaFrameGeneration.X2; s.target_fps = 90.0
        sub.apply_user_settings(s, True)
        s2 = sub.get_user_settings()
        ok = (s2.mode == unreal.MabaMode.QUALITY and abs(s2.sharpness - 0.35) < 1e-4
              and s2.frame_generation == unreal.MabaFrameGeneration.X2 and abs(s2.target_fps - 90.0) < 1e-3)
        log("apply round trip (mode %s, sharpness %.2f, FG %s, fps %.0f) -> %s" % (s2.mode, s2.sharpness, s2.frame_generation, s2.target_fps, "PASS" if ok else "FAIL"))
        st["menu"] = lib.show_maba_settings_menu(w(), 10, False)
        st["phase"] = "menu"; st["at"] = f
    elif st["phase"] == "menu":
        if f == st["at"] + 30:
            st["menu"].refresh_from_settings()
            log("settings menu created and in the viewport -> %s" % ("PASS" if st["menu"].is_in_viewport() else "FAIL"))
            for c in ("ShowFlag.Lighting 0", "t.MaxFPS 30", "r.Maba.Mode 3", "r.Maba.FrameGeneration.AutoPause 0", "r.Maba.FrameGeneration 2"): cmd(c)
            st["phase"] = "x3"; st["at"] = f
    elif st["phase"] == "x3":
        if f - st["at"] >= 150 and f - st["at"] < 210: st["seq"] += "G" if status().frame_generation_active else "R"
        if f - st["at"] == 210:
            ok = any(p * 20 in st["seq"] for p in ("RGG", "GGR", "GRG"))
            log("3x pattern %s... (one real, two generated) -> %s" % (st["seq"][:24], "PASS" if ok else "FAIL"))
            for c in ("r.Maba.FrameGeneration.AutoPause 1", "r.Maba.FrameGeneration 1", "r.VSync 1", "t.MaxFPS 0"): cmd(c)
            st["phase"] = "gov"; st["gov_start"] = f
    elif st["phase"] == "gov":
        s = status()
        if s.frame_generation_paused and st["paused_at"] is None:
            st["paused_at"] = f
            log("governor paused Frame Generation after %d ticks (vsync-bound scene) -> PASS" % (f - st["gov_start"]))
        if st["paused_at"] is not None and f > st["paused_at"] + 20:
            cmd("quit")
        if f - st["gov_start"] > 4000:
            log("governor did not pause within 4000 ticks -> FAIL"); cmd("quit")
unreal.register_slate_post_tick_callback(tick)