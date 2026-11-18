# Frame Generation capture test (run in game by run_unreal_fg_test.ps1). The pawn moves a fixed step every tick; with Frame Generation
# 2x, ticks alternate real / generated. A screenshot requested on a tick is taken on the NEXT tick's draw, so after a real tick comes a
# generated one. For every captured generated frame a truth is rendered afterwards (Frame Generation off, same pose, held until the
# temporal image converges); psnr_fg.ps1 compares them.
import os
import unreal
OUT = os.environ.get("MABA_SHOTS", "D:/temp/ue_proj/shots").replace("\\", "/")
STEP = 8.0
st = {"f": 0, "caps": [], "phase": "warm", "i": 0, "hold": 0, "tp": [], "start": 0}
def w(): return unreal.find_object(None, "/Game/TestMap.TestMap")
def cmd(c): unreal.log("MABACMD " + c); unreal.SystemLibrary.execute_console_command(w(), c)
def pose(i): return unreal.Vector(-420.0 + STEP * max(0, i - 300), 0.0, 120.0)
def pawn(): return unreal.GameplayStatics.get_player_pawn(w(), 0)
def setpose(i): pawn().set_actor_location(pose(i), False, False)
def lock_input():
    # The test window takes mouse-look like a game: a mouse movement (yours, while a test runs) would rotate the camera and ruin every comparison.
    pc = unreal.GameplayStatics.get_player_controller(w(), 0)
    if pc is not None:
        pc.set_ignore_look_input(True)
        pc.set_ignore_move_input(True)
def gen_now(): return unreal.MabaBlueprintLibrary.get_maba_status().frame_generation_active
def tick(dt):
    try: tick2(dt)
    except Exception as e:
        unreal.log("MABAFG EXC " + repr(e)); cmd("quit")
def tick2(dt):
    st["f"] += 1
    f = st["f"]
    if f == 3:
        for c in ("ShowFlag.Lighting 0", "t.MaxFPS 30", "r.Maba.Mode 3", "r.Maba.Temporal 1", "r.Maba.FrameGeneration.AutoPause 0", "r.Maba.FrameGeneration 1"):
            cmd(c)
    if f < 3: return
    if f == 3 or f % 30 == 0: lock_input()
    g = gen_now()
    if st["phase"] == "warm":
        setpose(f)
        if f == 330: st["phase"] = "cap"; st["start"] = f
    elif st["phase"] == "cap":
        setpose(f)
        if f - st["start"] < 24:
            kind = "real" if g else "gen"
            cmd("HighResShot 1 filename=%s/%s_%d.png" % (OUT, kind, f + 1))
            st["caps"].append((kind, f + 1))
        else:
            st["phase"] = "truth"; cmd("r.Maba.FrameGeneration 0")
            st["tp"] = [c[1] for c in st["caps"] if c[0] == "gen"][:4]
    elif st["phase"] == "truth":
        if st["i"] >= len(st["tp"]):
            unreal.log("MABAFG done"); cmd("quit"); return
        idx = st["tp"][st["i"]]
        setpose(idx)
        st["hold"] += 1
        if st["hold"] == 45: cmd("HighResShot 1 filename=%s/truth_%d.png" % (OUT, idx))
        if st["hold"] == 50: st["i"] += 1; st["hold"] = 0
unreal.register_slate_post_tick_callback(tick)