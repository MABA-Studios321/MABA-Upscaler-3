# Builds the Unreal test level (run by run_unreal_fg_test.ps1 through -ExecutePythonScript). A floor, six poles, a sphere and a cube:
# plenty of edges and depth steps for judging camera re-projection. The tests switch lighting off (ShowFlag.Lighting 0), which is what makes
# the picture readable on machines where the lit renderer produces black.
import unreal
eas = unreal.get_editor_subsystem(unreal.EditorActorSubsystem)
les = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
les.new_level('/Game/TestMap')
cube = unreal.EditorAssetLibrary.load_asset('/Engine/BasicShapes/Cube.Cube')
sphere = unreal.EditorAssetLibrary.load_asset('/Engine/BasicShapes/Sphere.Sphere')
cyl = unreal.EditorAssetLibrary.load_asset('/Engine/BasicShapes/Cylinder.Cylinder')
mat = unreal.EditorAssetLibrary.load_asset('/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial')
def spawn(mesh, loc, scale, rot=unreal.Rotator(0, 0, 0)):
    a = eas.spawn_actor_from_class(unreal.StaticMeshActor, loc, rot)
    c = a.static_mesh_component
    c.set_mobility(unreal.ComponentMobility.MOVABLE)
    c.set_static_mesh(mesh)
    c.set_material(0, mat)
    a.set_actor_scale3d(scale)
    return a
spawn(cube, unreal.Vector(0, 0, -50), unreal.Vector(40, 40, 1))
for i in range(6):
    spawn(cyl, unreal.Vector(300 + i * 120, -300 + i * 60, 150), unreal.Vector(0.15, 0.15, 3.0))
spawn(sphere, unreal.Vector(500, 0, 100), unreal.Vector(2, 2, 2))
spawn(cube, unreal.Vector(700, 250, 100), unreal.Vector(1.5, 1.5, 2), unreal.Rotator(0, 35, 0))
dl = eas.spawn_actor_from_class(unreal.DirectionalLight, unreal.Vector(0, 0, 500), unreal.Rotator(-45, 40, 0))
dl.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
eas.spawn_actor_from_class(unreal.PlayerStart, unreal.Vector(-200, 0, 120), unreal.Rotator(-5, 0, 0))
les.save_current_level()
unreal.log("MABAMAP saved")
unreal.SystemLibrary.execute_console_command(None, "QUIT_EDITOR")