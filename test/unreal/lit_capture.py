# Lit-scene check on an engine template map (run in game by hand / run_unreal_lit_test.ps1). Phases, all with the camera still unless noted:
#   engine  MABA off (the engine's own picture, 100% resolution)             -> 12 consecutive frames
#   maba    MABA temporal upscaler, Balanced, Frame Generation off           -> 12 consecutive frames
#   fg2x    + Frame Generation 2x                                            -> 12 consecutive frames
#   fg3x    Frame Generation 3x                                              -> 12 consecutive frames
#   move    camera moves a fixed step per tick, Frame Generation 2x          -> generated / real frames; then truth_NNN with Frame Generation off
import os
import unreal
OUT = os.environ.get("MABA_SHOTS").replace("\\", "/")
MAP = os.environ.get("MABA_MAP", "/Engine/Maps/Templates/Template_Default.Template_Default")
STEP = float(os.environ.get("MABA_STEP", "6.0"))
EXTRA = [x for x in os.environ.get("MABA_CVARS", "").split(";") if x.strip()]   # more console commands applied at the start, e.g. ShowFlag.EyeAdaptation 0
st = {"f": 0, "ph": "engine_warm", "t": 0, "n": 0, "caps": [], "tp": [], "i": 0, "hold": 0, "base": None}
def world(): return unreal.find_object(None, MAP)
def cmd(c): unreal.SystemLibrary.execute_console_command(world(), c)
def pawn(): return unreal.GameplayStatics.get_player_pawn(world(), 0)
def lock_input():
    # The test window takes mouse-look like a game: a mouse movement (yours, while a test runs) would rotate the camera and ruin every comparison.
    pc = unreal.GameplayStatics.get_player_controller(world(), 0)
    if pc is not None:
        pc.set_ignore_look_input(True)
        pc.set_ignore_move_input(True)
def gen_now(): return unreal.MabaBlueprintLibrary.get_maba_status().frame_generation_active
def cam_pose():
    cm = unreal.GameplayStatics.get_player_camera_manager(world(), 0)
    if cm is None: return None
    l = cm.get_camera_location(); r = cm.get_camera_rotation()
    return (round(l.x, 2), round(l.y, 2), round(l.z, 2), round(r.pitch, 2), round(r.yaw, 2), round(r.roll, 2))
def shot(name): cmd("HighResShot 1 filename=%s/%s.png" % (OUT, name))
def pose(i):
    b = st["base"]; return b[0] + b[1] * (STEP * max(0, i - 400))
def tick(dt):
    try: tick2()
    except Exception as e:
        unreal.log("LIT EXC " + repr(e)); cmd("quit")
def goto(ph):
    st["ph"] = ph; st["t"] = 0; st["n"] = 0
def tick2():
    st["f"] += 1; f = st["f"]; ph = st["ph"]
    if f == 3:
        cmd("r.Maba.Enable 0"); cmd("t.MaxFPS 60"); cmd("r.Maba.Mode 3"); cmd("r.Maba.Temporal 1"); cmd("r.Maba.FrameGeneration.AutoPause 0"); cmd("r.Maba.FrameGeneration 0")
        for e in EXTRA: cmd(e)
        return
    if f < 3: return
    if f == 3 or f % 30 == 0: lock_input()
    if st["base"] is None and pawn() is not None:
        st["base"] = (pawn().get_actor_location(), pawn().get_actor_forward_vector())
    st["t"] += 1; t = st["t"]
    if ph in ("engine_warm", "engine_cap", "maba_warm", "maba_cap", "fg_warm", "fg_cap", "fg3_warm", "fg3_cap") and st["base"] is not None and pawn() is not None:
        pawn().set_actor_location(st["base"][0], False, False)   # hold the camera still (the game mode can place the pawn late)
    pose_now = cam_pose()
    st["calm"] = st.get("calm", 0) + 1 if (pose_now is not None and pose_now == st.get("last_pose")) else 0
    st["last_pose"] = pose_now
    if ph == "engine_warm":
        # Start only once the player camera has not changed for 60 ticks (a fixed warm-up is not a reliable "settled" signal on a busy machine).
        if t >= 150 and st["calm"] >= 60: goto("engine_cap")
        elif t > 1200: unreal.log("LIT EXC the camera never settled"); cmd("quit")
    elif ph == "engine_cap":
        shot("engine_%03d_real" % st["n"]); st["n"] += 1
        if st["n"] >= 12: cmd("r.Maba.Enable 1"); goto("maba_warm")
    elif ph == "maba_warm":
        if t == 200: goto("maba_cap")
    elif ph == "maba_cap":
        shot("maba_%03d_real" % st["n"]); st["n"] += 1
        if st["n"] >= 12: cmd("r.Maba.FrameGeneration 1"); goto("fg_warm")
    elif ph == "fg_warm":
        if t == 120: goto("fg_cap")
    elif ph == "fg_cap":
        shot("fg2x_%03d_%s" % (st["n"], "real" if gen_now() else "gen")); st["n"] += 1
        if st["n"] >= 12: cmd("r.Maba.FrameGeneration 2"); goto("fg3_warm")
    elif ph == "fg3_warm":
        if t == 150: goto("fg3_cap")
    elif ph == "fg3_cap":
        shot("fg3x_%03d_%s" % (st["n"], "real" if gen_now() else "gen")); st["n"] += 1
        if st["n"] >= 12: cmd("r.Maba.FrameGeneration 1"); goto("move_warm"); st["f"] = 400 - 1
    elif ph == "move_warm":
        pawn().set_actor_location(pose(f), False, False)
        if f >= 430: goto("move_cap"); st["start"] = f
    elif ph == "move_cap":
        pawn().set_actor_location(pose(f), False, False)
        if f - st["start"] < 24:
            kind = "real" if gen_now() else "gen"
            shot("move_%s_%d" % (kind, f + 1)); st["caps"].append((kind, f + 1))
        else:
            cmd("r.Maba.FrameGeneration 0"); st["tp"] = [c[1] for c in st["caps"] if c[0] == "gen"][:4]; goto("truth")
    elif ph == "truth":
        if st["i"] >= len(st["tp"]):
            unreal.log("LIT done"); cmd("quit"); return
        idx = st["tp"][st["i"]]
        pawn().set_actor_location(pose(idx), False, False)
        st["hold"] += 1
        if st["hold"] == 60: shot("truth_%d" % idx)
        if st["hold"] == 66: st["i"] += 1; st["hold"] = 0
unreal.register_slate_post_tick_callback(tick)