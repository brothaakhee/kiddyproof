# Build Kiddy's stylized 3D cat — model, rig, and animation clips — entirely
# in headless Blender, then export a glTF binary ready for the app's
# KiddyCat3D pipeline (drop-in replacement for Resources/cat.glb).
#
#   blender -b -P Scripts/build_cat.py -- /path/out/cat.glb [/path/previews]
#
# Design: the smooth 3D realization of the brand silhouette — plump charcoal
# body, round head with tall ears, long expressive tail. Clips authored here:
#   Idle, Walk, Run, Sit, Lie, Idle_Eating, Headbutt, Jump_Start, Jump_Loop
import bpy
import math
import sys

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT_GLB = argv[0] if argv else "/tmp/cat.glb"
PREVIEW_DIR = argv[1] if len(argv) > 1 else None

FPS = 24
bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene
scn.render.fps = FPS

# ---------------------------------------------------------------- mesh parts
# Forward is +X, up is +Z. Ground plane z=0. Cat ~1.0 tall at ear tips.
def sphere(name, loc, scale, segments=24):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=segments // 2,
                                         radius=1, location=loc)
    ob = bpy.context.object
    ob.name = name
    ob.scale = scale
    return ob

def cone(name, loc, r, depth, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cone_add(vertices=12, radius1=r, radius2=0.015,
                                    depth=depth, location=loc, rotation=rot)
    ob = bpy.context.object
    ob.name = name
    return ob

def cyl(name, frm, to, r):
    dx, dy, dz = to[0] - frm[0], to[1] - frm[1], to[2] - frm[2]
    length = math.sqrt(dx * dx + dy * dy + dz * dz)
    mid = ((frm[0] + to[0]) / 2, (frm[1] + to[1]) / 2, (frm[2] + to[2]) / 2)
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=r, depth=length, location=mid)
    ob = bpy.context.object
    ob.name = name
    # rotate cylinder axis (z) onto the segment direction
    phi = math.atan2(dy, dx)
    theta = math.acos(max(-1, min(1, dz / length)))
    ob.rotation_euler = (0, theta, phi)
    return ob

parts = []
parts.append(sphere("body", (-0.02, 0, 0.62), (0.52, 0.26, 0.30)))
parts.append(sphere("chest", (0.30, 0, 0.64), (0.24, 0.22, 0.26)))
parts.append(sphere("haunch", (-0.38, 0, 0.60), (0.28, 0.26, 0.30)))
parts.append(sphere("head", (0.60, 0, 1.02), (0.23, 0.21, 0.21)))
parts.append(sphere("muzzle", (0.78, 0, 0.94), (0.09, 0.10, 0.07)))
parts.append(cone("ear.L", (0.54, 0.115, 1.27), 0.10, 0.26, (math.radians(-12), math.radians(8), 0)))
parts.append(cone("ear.R", (0.54, -0.115, 1.27), 0.10, 0.26, (math.radians(12), math.radians(8), 0)))
# legs: sturdy columns with paw spheres (thin ones get swallowed by the remesh)
for (tag, lx) in (("front", 0.32), ("hind", -0.36)):
    for (side, ly) in (("L", 0.14), ("R", -0.14)):
        parts.append(cyl(f"leg_{tag}.{side}", (lx, ly, 0.62), (lx, ly, 0.05), 0.075))
        parts.append(sphere(f"paw_{tag}.{side}", (lx + 0.02, ly, 0.05), (0.095, 0.08, 0.055)))
# tail: segmented column heading back and up, posed by bones later
TAIL_PTS = [(-0.58, 0, 0.72), (-0.80, 0, 0.86), (-0.92, 0, 1.06),
            (-0.95, 0, 1.26), (-0.92, 0, 1.44)]
for i in range(len(TAIL_PTS) - 1):
    r = 0.065 - i * 0.006
    parts.append(cyl(f"tailseg{i}", TAIL_PTS[i], TAIL_PTS[i + 1], r))
    # ball joints between segments keep the remesh from pinching at the kinks
    parts.append(sphere(f"tailjoint{i}", TAIL_PTS[i + 1],
                        (0.062 - i * 0.006,) * 3, segments=12))
parts.append(sphere("tailtip", TAIL_PTS[-1], (0.055, 0.055, 0.065)))

for ob in parts:
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(rotation=True, scale=True)

bpy.ops.object.select_all(action='DESELECT')
for ob in parts:
    ob.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
cat = bpy.context.object
cat.name = "Kiddy"

# weld the primitives into one smooth organic surface
rm = cat.modifiers.new("remesh", 'REMESH')
rm.mode = 'VOXEL'
rm.voxel_size = 0.032
rm.use_smooth_shade = True
bpy.ops.object.modifier_apply(modifier="remesh")
sub = cat.modifiers.new("subsurf", 'SUBSURF')
sub.levels = 1
bpy.ops.object.modifier_apply(modifier="subsurf")
bpy.ops.object.shade_smooth()

# charcoal coat
mat = bpy.data.materials.new("coat")
mat.use_nodes = True
bsdf = mat.node_tree.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.10, 0.095, 0.11, 1)
bsdf.inputs["Roughness"].default_value = 0.55
cat.data.materials.append(mat)

# eyes + nose: small bone-parented spheres (skinned with the head)
def accessory(name, loc, scale, color):
    ob = sphere(name, loc, scale, segments=16)
    m = bpy.data.materials.new(name + "_mat")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = color
    b.inputs["Roughness"].default_value = 0.25
    ob.data.materials.append(m)
    bpy.ops.object.shade_smooth()
    return ob

eyeL = accessory("eye.L", (0.745, 0.09, 1.07), (0.032, 0.028, 0.042), (0.82, 0.86, 0.72, 1))
eyeR = accessory("eye.R", (0.745, -0.09, 1.07), (0.032, 0.028, 0.042), (0.82, 0.86, 0.72, 1))
nose = accessory("nose", (0.865, 0, 0.965), (0.026, 0.028, 0.018), (0.75, 0.45, 0.48, 1))

# ------------------------------------------------------------------ armature
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
arm_ob = bpy.context.object
arm_ob.name = "AnimalArmature"
arm = arm_ob.data
eb = arm.edit_bones
eb[0].name = "root"
root = eb["root"]
root.head = (-0.28, 0, 0.62)
root.tail = (0.02, 0, 0.66)

def bone(name, head, tail, parent, connected=False):
    b = eb.new(name)
    b.head = head
    b.tail = tail
    b.parent = eb[parent]
    b.use_connect = connected
    return b

bone("chest", (0.02, 0, 0.66), (0.34, 0, 0.68), "root", True)
bone("neck", (0.34, 0, 0.68), (0.52, 0, 0.94), "chest", True)
bone("head", (0.52, 0, 0.94), (0.84, 0, 1.10), "neck", True)
for side, sy in (("L", 1), ("R", -1)):
    bone(f"leg_front_upper.{side}", (0.32, 0.14 * sy, 0.62), (0.32, 0.14 * sy, 0.32), "chest")
    bone(f"leg_front_lower.{side}", (0.32, 0.14 * sy, 0.32), (0.34, 0.14 * sy, 0.03),
         f"leg_front_upper.{side}", True)
    bone(f"leg_hind_upper.{side}", (-0.36, 0.14 * sy, 0.58), (-0.36, 0.14 * sy, 0.30), "root")
    bone(f"leg_hind_lower.{side}", (-0.36, 0.14 * sy, 0.30), (-0.34, 0.14 * sy, 0.03),
         f"leg_hind_upper.{side}", True)
prev = "root"
for i in range(len(TAIL_PTS) - 1):
    bone(f"tail{i}", TAIL_PTS[i], TAIL_PTS[i + 1], prev, i > 0)
    prev = f"tail{i}"
bpy.ops.object.mode_set(mode='OBJECT')

# skin: automatic weights for the body; eyes/nose ride the head bone
for ob in (cat, eyeL, eyeR, nose):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    arm_ob.select_set(True)
    bpy.context.view_layer.objects.active = arm_ob
    if ob is cat:
        bpy.ops.object.parent_set(type='ARMATURE_AUTO')
    else:
        bpy.ops.object.mode_set(mode='POSE')
        arm_ob.data.bones.active = arm_ob.data.bones["head"]
        bpy.ops.object.parent_set(type='BONE')
        bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------- animations
# All posing is WORLD-SPACE: each bone is rotated about explicit world axes
# via rest-matrix conjugation (basis = M⁻¹·R_world·M), so there is no
# bone-local axis guessing anywhere. Conventions (cat faces +X):
#   pitch +θ = tip/nose swings UP (rotation about world -Y)
#   sway  +θ = tip swings LEFT (rotation about world +X... seen from front)
#   worldz    = vertical offset in world units
import mathutils

P = arm_ob.pose.bones

def clear_pose():
    for pb in P:
        pb.location = (0, 0, 0)
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = (0, 0, 0)
        pb.scale = (1, 1, 1)

def key_all(frame):
    for pb in P:
        pb.keyframe_insert("location", frame=frame)
        pb.keyframe_insert("rotation_euler", frame=frame)

def pose(name, pitch=0.0, sway=0.0, worldz=0.0, worldx=0.0):
    pb = P[name]
    R = (mathutils.Matrix.Rotation(math.radians(-pitch), 4, 'Y')
         @ mathutils.Matrix.Rotation(math.radians(sway), 4, 'X'))
    M = pb.bone.matrix_local.to_3x3().to_4x4()
    basis = M.inverted() @ R @ M
    pb.rotation_euler = basis.to_euler('XYZ')
    if worldz or worldx:
        off = M.inverted() @ mathutils.Vector((worldx, 0, worldz))
        pb.location = off

# The neutral standing S-tail carriage, reused by most clips.
# The mesh's rest tail IS the raised brand S — the carriage only adds life.
def tail_carriage(sway=0.0):
    pose("tail0", pitch=3, sway=sway * 10)
    pose("tail1", pitch=2, sway=sway * 16)
    pose("tail2", pitch=0, sway=sway * 22)
    pose("tail3", pitch=-4, sway=sway * 28)

actions = {}
def new_action(name, length):
    act = bpy.data.actions.new(name)
    arm_ob.animation_data_create()
    arm_ob.animation_data.action = act
    scn.frame_start = 1
    scn.frame_end = length
    actions[name] = act
    return act

# Idle: weight settled, breathing, tail alive.
new_action("Idle", 96)
for f in range(1, 97, 8):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("chest", worldz=0.008 * math.sin(t * 2))
    pose("head", pitch=2 + 2.0 * math.sin(t * 2 + 0.8))
    tail_carriage(sway=math.sin(t))
    key_all(f)

# Walk: lateral-sequence gait, gentle bob. Legs point down: pitch swings them
# fore/aft (positive pitch moves a downward bone's tip backward).
new_action("Walk", 24)
for f in range(1, 25, 2):
    t = (f - 1) / 24 * 2 * math.pi
    clear_pose()
    for name, ph in (("leg_front_upper.L", 0), ("leg_front_upper.R", math.pi),
                     ("leg_hind_upper.L", math.pi * 0.9), ("leg_hind_upper.R", math.pi * 1.9)):
        s = math.sin(t + ph)
        pose(name, pitch=26 * s)
        # knee flexes as the leg swings forward (tip forward = negative pitch)
        pose(name.replace("upper", "lower"), pitch=-max(0.0, 30 * math.sin(t + ph + math.pi / 3)))
    pose("root", worldz=0.012 * math.sin(t * 2))
    pose("head", pitch=3)
    tail_carriage(sway=0.5 * math.sin(t))
    key_all(f)

# Run: bound — front pair then hind pair, body rocking.
new_action("Run", 14)
for f in range(1, 15):
    t = (f - 1) / 14 * 2 * math.pi
    clear_pose()
    for name, ph in (("leg_front_upper.L", 0), ("leg_front_upper.R", 0.5),
                     ("leg_hind_upper.L", math.pi), ("leg_hind_upper.R", math.pi + 0.5)):
        s = math.sin(t + ph)
        pose(name, pitch=40 * s)
        pose(name.replace("upper", "lower"), pitch=-max(0.0, 44 * math.sin(t + ph + math.pi / 3)))
    pose("root", pitch=6 * math.sin(t), worldz=0.05 * max(0.0, math.sin(t)))
    pose("head", pitch=6)
    tail_carriage()
    key_all(f)

# Sit: the royal sit — pelvis dropped, spine rising ~40°, tail wrapped.
new_action("Sit", 96)
for f in range(1, 97, 12):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("root", pitch=28, worldz=-0.24)
    pose("chest", pitch=12 + 0.6 * math.sin(t * 2))
    pose("neck", pitch=6)
    pose("head", pitch=-12 + 1.5 * math.sin(t * 2 + 1))
    for side in "LR":
        # thighs fold forward, shins fold back beneath; front legs stay planted
        pose(f"leg_hind_upper.{side}", pitch=-64)
        pose(f"leg_hind_lower.{side}", pitch=58)
        pose(f"leg_front_upper.{side}", pitch=-30)
        pose(f"leg_front_lower.{side}", pitch=-4)
    pose("tail0", pitch=-30, sway=8)
    pose("tail1", pitch=-26, sway=20)
    pose("tail2", pitch=-10, sway=30)
    pose("tail3", pitch=6, sway=24)
    key_all(f)

# Lie: the loaf — dropped to the ground, all legs tucked, slow breath.
new_action("Lie", 96)
for f in range(1, 97, 12):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("root", worldz=-0.33 + 0.006 * math.sin(t * 2))
    for side in "LR":
        pose(f"leg_hind_upper.{side}", pitch=-58)
        pose(f"leg_hind_lower.{side}", pitch=64)
        pose(f"leg_front_upper.{side}", pitch=52)
        pose(f"leg_front_lower.{side}", pitch=-66)
    pose("neck", pitch=-6)
    pose("head", pitch=-4 + 1.2 * math.sin(t * 2))
    pose("tail0", pitch=-18, sway=26)
    pose("tail1", pitch=-8, sway=36)
    pose("tail2", pitch=4, sway=36)
    pose("tail3", pitch=10, sway=24)
    key_all(f)

# Idle_Eating: head down to the bowl, nibbling bob.
new_action("Idle_Eating", 72)
for f in range(1, 73, 6):
    t = (f - 1) / 71 * 2 * math.pi
    clear_pose()
    pose("chest", pitch=-8)
    pose("neck", pitch=-34)
    pose("head", pitch=-30 - 3.5 * math.sin(t * 3))
    tail_carriage(sway=0.3 * math.sin(t))
    key_all(f)

# Headbutt → PLAY: crouched front, wiggling rump, one paw swatting.
new_action("Headbutt", 48)
for f in range(1, 49, 4):
    t = (f - 1) / 47 * 2 * math.pi
    clear_pose()
    pose("root", pitch=10, worldz=-0.10)
    pose("chest", pitch=-10)
    pose("neck", pitch=-16)
    pose("head", pitch=-8 - 4 * math.sin(t * 2))
    swat = max(0.0, math.sin(t * 2))
    pose("leg_front_upper.L", pitch=-55 * swat)
    pose("leg_front_lower.L", pitch=-25 * swat)
    tail_carriage(sway=math.sin(t * 1.5))
    key_all(f)

# Jump_Start: the windup crouch.
new_action("Jump_Start", 10)
for f, crouch in ((1, 0.0), (5, 1.0), (10, 1.0)):
    clear_pose()
    pose("root", pitch=-6 * crouch, worldz=-0.17 * crouch)
    pose("neck", pitch=-8 * crouch)
    for side in "LR":
        pose(f"leg_front_upper.{side}", pitch=-26 * crouch)
        pose(f"leg_front_lower.{side}", pitch=30 * crouch)
        pose(f"leg_hind_upper.{side}", pitch=-30 * crouch)
        pose(f"leg_hind_lower.{side}", pitch=38 * crouch)
    pose("tail0", pitch=10)
    key_all(f)

# Jump_Loop: airborne reach — forelegs forward, hind trailing, tail high.
new_action("Jump_Loop", 20)
for f in range(1, 21, 4):
    t = (f - 1) / 19 * 2 * math.pi
    clear_pose()
    pose("root", pitch=12)
    pose("chest", pitch=6)
    pose("head", pitch=-4)
    for side in "LR":
        pose(f"leg_front_upper.{side}", pitch=-52)
        pose(f"leg_front_lower.{side}", pitch=14)
        pose(f"leg_hind_upper.{side}", pitch=42)
        pose(f"leg_hind_lower.{side}", pitch=10)
    pose("tail0", pitch=22 + 2 * math.sin(t))
    pose("tail1", pitch=12)
    key_all(f)

# Push every action onto its own NLA track so the exporter writes one glTF
# animation per clip.
arm_ob.animation_data.action = None
for name, act in actions.items():
    track = arm_ob.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, 1, act)
    strip.name = name

# ------------------------------------------------------------------ previews
if PREVIEW_DIR:
    scn.render.engine = 'BLENDER_WORKBENCH'
    scn.display.shading.light = 'STUDIO'
    scn.display.shading.color_type = 'MATERIAL'
    scn.render.resolution_x = 640
    scn.render.resolution_y = 480
    scn.render.film_transparent = True
    bpy.ops.object.camera_add(location=(0.1, -3.6, 1.0),
                              rotation=(math.radians(86), 0, 0))
    scn.camera = bpy.context.object
    for name in ("Idle", "Walk", "Sit", "Lie", "Jump_Loop", "Idle_Eating"):
        for tr in arm_ob.animation_data.nla_tracks:
            tr.mute = tr.name != name
        frame = {"Idle": 1, "Walk": 7, "Sit": 49, "Lie": 49,
                 "Jump_Loop": 9, "Idle_Eating": 37}[name]
        scn.frame_set(frame)
        scn.render.filepath = f"{PREVIEW_DIR}/pose_{name}.png"
        bpy.ops.render.render(write_still=True)
    for tr in arm_ob.animation_data.nla_tracks:
        tr.mute = False

# -------------------------------------------------------------------- export
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format='GLB',
                          export_animations=True, export_apply=False,
                          export_yup=True)
print(f"BUILD-CAT-DONE {OUT_GLB}")
