# Flicker check (run in game by run_unreal_fg_test.ps1 / by hand). Captures CONSECUTIVE displayed frames with Frame Generation on, once with a
# still camera and once with a camera moving at a constant speed. flicker_check.ps1 then compares each frame with the next one: with a still
# camera every displayed frame must be identical (real or generated), with constant motion the steps must be equal in size and brightness.
#
# Environment: MABA_SHOTS (output folder), MABA_FG (0 off, 1 = 2x, 2 = 3x), MABA_ENABLE (0 = MABA off completely, the engine alone),
# MABA_CVARS (extra console commands separated by ;), MABA_HUD (1 = show UI and capture with "Shot showui", still camera only).
import os
import unreal
OUT = os.environ.get("MABA_SHOTS", "D:/temp/ue_proj/flicker").replace("\\", "/")
FG = os.environ.get("MABA_FG", "1")
ON = os.environ.get("MABA_ENABLE", "1")
HUD = os.environ.get("MABA_HUD", "0") == "1"
EXTRA = [x for x in os.environ.get("MABA_CVARS", "").split(";") if x.strip()]
st = {"f": 0, "phase": "warm", "n": 0, "t": 0}


def w(): return unreal.find_object(None, "/Game/TestMap.TestMap")
def cmd(c): unreal.SystemLibrary.execute_console_command(w(), c)
def pawn(): return unreal.GameplayStatics.get_player_pawn(w(), 0)
def lock_input():
    # The test window takes mouse-look like a game: a mouse movement (yours, while a test runs) would rotate the camera and ruin every comparison.
    pc = unreal.GameplayStatics.get_player_controller(w(), 0)
    if pc is not None:
        pc.set_ignore_look_input(True)
        pc.set_ignore_move_input(True)
def gen_now(): return unreal.MabaBlueprintLibrary.get_maba_status().frame_generation_active
def cam_pose():
    cm = unreal.GameplayStatics.get_player_camera_manager(w(), 0)
    if cm is None: return None
    l = cm.get_camera_location(); r = cm.get_camera_rotation()
    return (round(l.x, 2), round(l.y, 2), round(l.z, 2), round(r.pitch, 2), round(r.yaw, 2), round(r.roll, 2))


def tick(dt):
    try:
        tick2(dt)
    except Exception as e:
        unreal.log("MABAFL EXC " + repr(e))
        cmd("quit")


def tick2(dt):
    st["f"] += 1
    f = st["f"]
    if f == 3:
        for c in ("ShowFlag.Lighting 0", "t.MaxFPS 60", "r.Maba.Enable " + ON, "r.Maba.Mode 3", "r.Maba.Temporal 1",
                  "r.Maba.FrameGeneration.AutoPause 0", "r.Maba.FrameGeneration " + FG):
            cmd(c)
        if HUD:
            # UI that must stay on screen on every displayed frame, generated ones included: the UMG settings menu (Slate) and canvas text.
            unreal.MabaBlueprintLibrary.show_maba_settings_menu(w(), 10, False)
            unreal.SystemLibrary.print_string(w(), "MABA HUD TEXT", True, False, unreal.LinearColor(1.0, 1.0, 0.0, 1.0), 1000.0)
        for c in EXTRA:
            cmd(c)
        pawn().set_actor_location(unreal.Vector(-300.0, 0.0, 120.0), False, False)
    if f < 3:
        return
    if f == 3 or f % 30 == 0:
        lock_input()
    if st["phase"] in ("warm", "still", "settle") and pawn() is not None:
        # Hold the camera still by placing it every tick: on a loaded machine the game mode can (re)place the pawn late, which once moved the
        # camera in the middle of a capture and looked like a flicker failure.
        pawn().set_actor_location(unreal.Vector(-300.0, 0.0, 120.0), False, False)
    pose_now = cam_pose()
    st["calm"] = st.get("calm", 0) + 1 if (pose_now is not None and pose_now == st.get("last_pose")) else 0
    st["last_pose"] = pose_now
    if st["phase"] == "warm":
        # Start only when the player camera has not changed for 60 ticks: a fixed warm-up is not a reliable "settled" signal on a busy machine
        # (the pawn can be placed or possessed late, and the frames of a moving camera are not "still").
        if f >= 120 and st["calm"] >= 60:
            st["phase"] = "still"
            st["n"] = 0
            st["t"] = 0
        elif f > 900:
            unreal.log("MABAFL EXC the camera never settled"); cmd("quit")
    elif st["phase"] == "still":
        if HUD:
            # One screenshot every 3rd tick: with Frame Generation 2x the shots alternate between real and generated frames. The engine names
            # them ScreenShotNNNNN.png and the PowerShell side collects them. Frame-to-frame equality then proves the UI is on every frame.
            st["t"] += 1
            if st["t"] % 3 == 1:
                cmd("Shot showui")
                st["n"] += 1
            if st["n"] >= 18:
                unreal.log("MABAFL done")
                cmd("quit")
        else:
            # The shot requested now is taken on the next tick's draw; the kind is what that next tick is.
            cmd("HighResShot 1 filename=%s/still_%03d_%s.png" % (OUT, st["n"], "real" if gen_now() else "gen"))
            st["n"] += 1
            if st["n"] >= 18:
                st["phase"] = "settle"
                st["n"] = 0
    elif st["phase"] == "settle":
        st["n"] += 1
        if st["n"] == 10:
            st["phase"] = "move"
            st["n"] = 0
            st["x"] = -300.0
    elif st["phase"] == "move":
        st["x"] += 4.0
        pawn().set_actor_location(unreal.Vector(st["x"], 0.0, 120.0), False, False)
        cmd("HighResShot 1 filename=%s/move_%03d_%s.png" % (OUT, st["n"], "real" if gen_now() else "gen"))
        st["n"] += 1
        if st["n"] >= 18:
            unreal.log("MABAFL done")
            cmd("quit")


unreal.register_slate_post_tick_callback(tick)
