# Rig and animate a GENERATED cat mesh (Meshy text-to-3D output) with the
# same skeleton and authored clips as the built cat, then export an animated
# GLB for the app's KiddyCat3D pipeline.
#
#   blender -b -P Scripts/rig_cat.py -- input_mesh.glb output_cat.glb [previews]
#
# The mesh is normalized to the canonical frame (+X forward, z=0 ground,
# ~1.3 tall) and the bones are FITTED TO MEASURED LANDMARKS (leg clusters,
# body core, head, tail path) rather than fixed positions, so any reasonably
# standing quadruped mesh rigs cleanly.
import bpy
import math
import sys
import mathutils

argv = sys.argv[sys.argv.index("--") + 1:]
IN_GLB, OUT_GLB = argv[0], argv[1]
PREVIEW_DIR = argv[2] if len(argv) > 2 else None

FPS = 24
bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene
scn.render.fps = FPS

# ------------------------------------------------------------------- import
if IN_GLB.lower().endswith(".fbx"):
    bpy.ops.import_scene.fbx(filepath=IN_GLB)
else:
    bpy.ops.import_scene.gltf(filepath=IN_GLB)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
bpy.ops.object.select_all(action='DESELECT')
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
cat = bpy.context.view_layer.objects.active
cat.name = "Kiddy"
# Bake the parent/importer transform chain straight into the vertex data.
# NOTE: bpy.ops.transform_apply fails SILENTLY on the importer's multi-user
# mesh data — mesh.transform() is deterministic and cannot.
cat.data = cat.data.copy()
world = cat.matrix_world.copy()
cat.parent = None
cat.matrix_world = mathutils.Matrix.Identity(4)
cat.data.transform(world)
for o in list(bpy.data.objects):
    if o.type != 'MESH':
        bpy.data.objects.remove(o, do_unlink=True)

# Slim the material for the in-app loader: GLTFSceneKit takes minutes on
# multi-2048² PBR texture sets (the app watchdog reads it as a hang). Keep
# only the base-color map, downsized; flat dielectric response elsewhere.
for mat in cat.data.materials:
    if not mat or not mat.use_nodes:
        continue
    bsdf = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if not bsdf:
        continue
    for inp_name in ("Metallic", "Specular IOR Level", "Roughness"):
        inp = bsdf.inputs.get(inp_name)
        if inp:
            for link in list(inp.links):
                mat.node_tree.links.remove(link)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.88   # soft fur, not vinyl
for img in bpy.data.images:
    # keep fur detail: base color at 2048, data maps at 1024
    limit = 2048 if "base" in img.name.lower() or "color" in img.name.lower() else 1024
    if img.size[0] > limit:
        img.scale(limit, limit)

# ---------------------------------------------------------------- normalize
# Generated models arrive at arbitrary yaw (Meshy: head at -Y; the chibi
# kitten: ~45°). Auto-align: PCA of the horizontal vertex spread gives the
# body axis; rotate it onto X. Then pick the head end as the end with the
# DENSER mass up high (a head+ears is chunky; a raised tail is a thin tube).
raw = [v.co.copy() for v in cat.data.vertices]
n = len(raw)
mx = sum(v.x for v in raw) / n
my = sum(v.y for v in raw) / n
sxx = sum((v.x - mx) ** 2 for v in raw) / n
syy = sum((v.y - my) ** 2 for v in raw) / n
sxy = sum((v.x - mx) * (v.y - my) for v in raw) / n
theta = 0.5 * math.atan2(2 * sxy, sxx - syy)
cat.data.transform(mathutils.Matrix.Rotation(-theta, 4, 'Z'))
vs0 = [v.co.copy() for v in cat.data.vertices]
zlo = min(v.z for v in vs0)
zhi = max(v.z for v in vs0)
xlo = min(v.x for v in vs0)
xhi = max(v.x for v in vs0)
zcut = zlo + 0.55 * (zhi - zlo)
span = xhi - xlo
front_mass = sum(1 for v in vs0 if v.z > zcut and v.x > xhi - 0.35 * span)
rear_mass = sum(1 for v in vs0 if v.z > zcut and v.x < xlo + 0.35 * span)
if rear_mass > front_mass:
    cat.data.transform(mathutils.Matrix.Rotation(math.pi, 4, 'Z'))
print(f"ORIENT theta={math.degrees(theta):.1f}deg head_mass f={front_mass} r={rear_mass} "
      f"flipped={rear_mass > front_mass}")

def verts():
    return [v.co.copy() for v in cat.data.vertices]

vs = verts()
zmin = min(v.z for v in vs)
zmax = max(v.z for v in vs)
scale = 1.30 / (zmax - zmin)
cat.data.transform(mathutils.Matrix.Scale(scale, 4))
vs = verts()
zmin = min(v.z for v in vs)
cat.data.transform(mathutils.Matrix.Translation((0, 0, -zmin)))

# ---------------------------------------------------------------- landmarks
# Whiskers flare far out laterally — clamp |y| for every body measurement.
vs = [v for v in verts() if abs(v.y) < 0.30]
H = max(v.z for v in vs)

# Legs: low vertices cluster along x into hind/front. Exclude a possible
# ground-touching tail by ignoring the extreme rear 8% until clustered.
low = [v for v in vs if v.z < 0.20]
lx = sorted(v.x for v in low)
xmid = lx[len(lx) // 2]
front = [v for v in low if v.x > xmid]
hind = [v for v in low if v.x <= xmid]
def robust_mean(vals):
    s = sorted(vals)
    k = len(s) // 5
    core = s[k:len(s) - k] or s
    return sum(core) / len(core)
xf = robust_mean([v.x for v in front])
xh = robust_mean([v.x for v in hind])
yspread_f = robust_mean([abs(v.y) for v in front])
yspread_h = robust_mean([abs(v.y) for v in hind])

# center the leg span on the origin
shift = -(xf + xh) / 2
cat.data.transform(mathutils.Matrix.Translation((shift, 0, 0)))
xf += shift
xh += shift
vs = [v for v in verts() if abs(v.y) < 0.30]

# Body core height: vertices between the legs → spine line.
core = [v for v in vs if xh + 0.1 < v.x < xf - 0.1]
core_z = sorted(v.z for v in core)
belly_z = core_z[int(len(core_z) * 0.25)]
back_z = core_z[int(len(core_z) * 0.96)]
spine_z = (belly_z + back_z) / 2

# Head: forward vertices → centroid + nose tip.
headv = [v for v in vs if v.x > xf + 0.12]
nose_x = max(v.x for v in headv)
head_cz = robust_mean([v.z for v in headv if v.z > spine_z])

# Tail: vertices behind the hind legs.
tailv = [v for v in vs if v.x < xh - 0.14]
TAIL_PTS = []
if len(tailv) > 40:
    tailv.sort(key=lambda v: -v.x)   # from base to tip going rearward
    n = len(tailv)
    for i in range(5):
        seg = tailv[int(n * i / 5):int(n * (i + 1) / 5)]
        TAIL_PTS.append((robust_mean([v.x for v in seg]),
                         robust_mean([v.y for v in seg]),
                         robust_mean([v.z for v in seg])))
    # smooth the chain: quantile centroids zigzag on a curled tail
    for _ in range(2):
        for i in range(1, 4):
            TAIL_PTS[i] = tuple((TAIL_PTS[i - 1][k] + 2 * TAIL_PTS[i][k]
                                 + TAIL_PTS[i + 1][k]) / 4 for k in range(3))
else:
    TAIL_PTS = [(xh - 0.2, 0, spine_z), (xh - 0.4, 0, spine_z + 0.1),
                (xh - 0.5, 0, spine_z + 0.3), (xh - 0.5, 0, spine_z + 0.5),
                (xh - 0.45, 0, spine_z + 0.65)]

# Legs begin at the belly line, not at spine height — a leg bone that
# passes through the torso drags body mass when the leg folds.
leg_top = max(belly_z + 0.06, 0.5 * spine_z)
print(f"LANDMARKS xf={xf:.2f} xh={xh:.2f} yf={yspread_f:.2f} yh={yspread_h:.2f} "
      f"spine_z={spine_z:.2f} belly_z={belly_z:.2f} head_cz={head_cz:.2f} nose_x={nose_x:.2f} "
      f"tail={['%.2f,%.2f' % (p[0], p[2]) for p in TAIL_PTS]}")

# ------------------------------------------------------------------ armature
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
arm_ob = bpy.context.object
arm_ob.name = "AnimalArmature"
eb = arm_ob.data.edit_bones
eb[0].name = "root"
root = eb["root"]
root.head = (xh + 0.06, 0, spine_z)
root.tail = (0.0, 0, spine_z + 0.02)

def bone(name, head, tail, parent, connected=False):
    b = eb.new(name)
    b.head = head
    b.tail = tail
    b.parent = eb[parent]
    b.use_connect = connected
    return b

neck_base = (xf + 0.06, 0, spine_z + 0.10)
bone("chest", (0.0, 0, spine_z + 0.02), (xf + 0.02, 0, spine_z + 0.04), "root", True)
bone("neck", neck_base, (xf + 0.16, 0, head_cz - 0.06), "chest")
bone("head", (xf + 0.16, 0, head_cz - 0.06), (nose_x - 0.02, 0, head_cz + 0.02), "neck", True)
knee = leg_top * 0.52
for side, sy in (("L", 1), ("R", -1)):
    bone(f"leg_front_upper.{side}", (xf, yspread_f * sy, leg_top),
         (xf, yspread_f * sy, knee), "chest")
    bone(f"leg_front_lower.{side}", (xf, yspread_f * sy, knee),
         (xf + 0.02, yspread_f * sy, 0.03), f"leg_front_upper.{side}", True)
    bone(f"leg_hind_upper.{side}", (xh, yspread_h * sy, leg_top),
         (xh, yspread_h * sy, knee), "root")
    bone(f"leg_hind_lower.{side}", (xh, yspread_h * sy, knee),
         (xh + 0.02, yspread_h * sy, 0.03), f"leg_hind_upper.{side}", True)
prev = "root"
for i in range(len(TAIL_PTS) - 1):
    bone(f"tail{i}", TAIL_PTS[i], TAIL_PTS[i + 1], prev, i > 0)
    prev = f"tail{i}"
bpy.ops.object.mode_set(mode='OBJECT')

# ---------------------------------------------------------------------- skin
# Generated meshes are a soup of disconnected shell patches (this one: 200+
# components), which makes bone-heat auto-weights shred at every joint.
# Distance-based gaussian weights ignore connectivity entirely and vary
# smoothly in space — soft, tear-free skinning for patchwork geometry.
bpy.ops.object.select_all(action='DESELECT')
cat.select_set(True)
arm_ob.select_set(True)
bpy.context.view_layer.objects.active = arm_ob
bpy.ops.object.parent_set(type='ARMATURE_NAME')   # empty groups, we fill them

SIGMA = {"root": 0.30, "chest": 0.28, "neck": 0.15, "head": 0.22}
def sigma_for(name):
    if name.startswith("leg"): return 0.10
    if name.startswith("tail"): return 0.06
    return SIGMA.get(name, 0.15)

def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (p - (a + ab * t)).length

bones_info = []
for b in arm_ob.data.bones:
    if not b.use_deform:
        continue
    bones_info.append((cat.vertex_groups[b.name],
                       mathutils.Vector(b.head_local),
                       mathutils.Vector(b.tail_local),
                       sigma_for(b.name)))
for v in cat.data.vertices:
    p = v.co
    ws = []
    for vg, hb, tb, sg in bones_info:
        d = seg_dist(p, hb, tb)
        ws.append((vg, math.exp(-(d / sg) ** 2)))
    ws.sort(key=lambda t: -t[1])
    ws = ws[:4]
    total = sum(w for _, w in ws) or 1.0
    for vg, w in ws:
        if w / total > 0.01:
            vg.add([v.index], w / total, 'REPLACE')

# ---------------------------------------------------------------- animations
# Identical authoring to Scripts/build_cat.py (world-space rest-conjugated
# posing), with grounding drops derived from the measured geometry.
P = arm_ob.pose.bones
PELVIS_DROP = -0.55 * spine_z          # sit: pelvis to ~45% hip height
# The patch-soup interior makes the belly unmeasurable directly; the body
# radius is ~0.24 around the spine line, so ground contact ≈ spine - 0.26.
BELLY_DROP = -(spine_z - 0.20)

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
        pb.keyframe_insert("scale", frame=frame)

def pose(name, pitch=0.0, sway=0.0, worldz=0.0, worldx=0.0):
    pb = P[name]
    R = (mathutils.Matrix.Rotation(math.radians(-pitch), 4, 'Y')
         @ mathutils.Matrix.Rotation(math.radians(sway), 4, 'X'))
    M = pb.bone.matrix_local.to_3x3().to_4x4()
    basis = M.inverted() @ R @ M
    pb.rotation_euler = basis.to_euler('XYZ')
    if worldz or worldx:
        pb.location = M.inverted() @ mathutils.Vector((worldx, 0, worldz))

def tail_carriage(sway=0.0):
    # The generated tail's rest pose is whatever Meshy grew — keep motion
    # relative and gentle.
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

new_action("Idle", 96)
for f in range(1, 97, 8):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("chest", worldz=0.008 * math.sin(t * 2))
    pose("head", pitch=2 + 2.0 * math.sin(t * 2 + 0.8))
    tail_carriage(sway=math.sin(t))
    key_all(f)

new_action("Walk", 24)
for f in range(1, 25):
    t = (f - 1) / 24 * 2 * math.pi
    clear_pose()
    for name, ph in (("leg_front_upper.L", 0), ("leg_front_upper.R", math.pi),
                     ("leg_hind_upper.L", math.pi * 0.9), ("leg_hind_upper.R", math.pi * 1.9)):
        s = math.sin(t + ph)
        swing = max(0.0, math.sin(t + ph + math.pi / 2.6))
        pose(name, pitch=24 * s)
        # stance leg stays straight and planted; swing leg flexes to clear
        pose(name.replace("upper", "lower"), pitch=-42 * swing ** 2)
    pose("root", worldz=0.010 * math.sin(t * 2), sway=2.0 * math.sin(t))
    pose("chest", sway=-1.4 * math.sin(t))
    pose("neck", pitch=2)
    pose("head", pitch=1.5 + 1.2 * math.sin(t * 2 + 0.6))
    tail_carriage(sway=0.35 * math.sin(t - 0.8))
    key_all(f)

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

new_action("Sit", 96)
for f in range(1, 97, 12):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("root", pitch=16, worldz=PELVIS_DROP)
    pose("chest", pitch=8 + 0.6 * math.sin(t * 2))
    pose("neck", pitch=6)
    pose("head", pitch=-2 + 1.5 * math.sin(t * 2 + 1))
    for side in "LR":
        pose(f"leg_hind_upper.{side}", pitch=-64)
        pose(f"leg_hind_lower.{side}", pitch=58)
        for seg in ("upper", "lower"):
            P[f"leg_hind_{seg}.{side}"].scale = (0.75, 0.75, 0.75)
        pose(f"leg_front_upper.{side}", pitch=-13)
        pose(f"leg_front_lower.{side}", pitch=-2)
    # keep the tail near its raised rest — hard bends collapse the thin
    # generated tail geometry into a rod
    pose("tail0", pitch=-16, sway=6)
    pose("tail1", pitch=-10, sway=12)
    pose("tail2", pitch=-4, sway=18)
    pose("tail3", pitch=0, sway=14)
    key_all(f)

new_action("Lie", 96)
for f in range(1, 97, 12):
    t = (f - 1) / 95 * 2 * math.pi
    clear_pose()
    pose("root", worldz=BELLY_DROP + 0.006 * math.sin(t * 2))
    for side in "LR":
        pose(f"leg_hind_upper.{side}", pitch=-48)
        pose(f"leg_hind_lower.{side}", pitch=52)
        for seg in ("upper", "lower"):
            P[f"leg_hind_{seg}.{side}"].scale = (0.5, 0.5, 0.5)
        # sphinx forelegs: folded flat along the ground, paws forward
        pose(f"leg_front_upper.{side}", pitch=-54)
        pose(f"leg_front_lower.{side}", pitch=48)
        P[f"leg_front_lower.{side}"].scale = (0.7, 0.7, 0.7)
    pose("neck", pitch=16)
    pose("head", pitch=4 + 1.2 * math.sin(t * 2))
    pose("tail0", pitch=-20, sway=18)
    pose("tail1", pitch=-12, sway=26)
    pose("tail2", pitch=-6, sway=26)
    pose("tail3", pitch=0, sway=18)
    key_all(f)

new_action("Idle_Eating", 72)
for f in range(1, 73, 6):
    t = (f - 1) / 71 * 2 * math.pi
    clear_pose()
    pose("chest", pitch=-8)
    pose("neck", pitch=-34)
    pose("head", pitch=-30 - 3.5 * math.sin(t * 3))
    tail_carriage(sway=0.3 * math.sin(t))
    key_all(f)

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

# Skid: braking slide — forepaws thrust forward and shuffling, rump high,
# weight back, tail flung up. Plays while ground speed bleeds off.
new_action("Skid", 12)
for f in range(1, 13):
    t = (f - 1) / 12 * 2 * math.pi
    clear_pose()
    pose("root", pitch=8, worldz=-0.10 * spine_z)
    pose("chest", pitch=-6)
    pose("neck", pitch=10)
    pose("head", pitch=6)
    shuffle = math.sin(t * 3)
    for side, sgn in (("L", 1), ("R", -1)):
        pose(f"leg_front_upper.{side}", pitch=-34 + 7 * shuffle * sgn)
        pose(f"leg_front_lower.{side}", pitch=6 - 4 * shuffle * sgn)
        pose(f"leg_hind_upper.{side}", pitch=-26 - 5 * shuffle * sgn)
        pose(f"leg_hind_lower.{side}", pitch=30)
    pose("tail0", pitch=16)
    pose("tail1", pitch=10, sway=6 * shuffle)
    pose("tail2", pitch=4, sway=10 * shuffle)
    key_all(f)

# Sit_Up: rear onto the haunches and paw upward at something overhead.
new_action("Sit_Up", 48)
for f in range(1, 49, 3):
    t = (f - 1) / 47 * 2 * math.pi
    clear_pose()
    pose("root", pitch=38, worldz=-0.52 * spine_z)
    pose("chest", pitch=26)
    pose("neck", pitch=24)
    pose("head", pitch=30 + 3 * math.sin(t * 2))
    paw = math.sin(t * 2)
    pose("leg_front_upper.L", pitch=-88 - 16 * max(0.0, paw))
    pose("leg_front_lower.L", pitch=-24 + 10 * max(0.0, paw))
    pose("leg_front_upper.R", pitch=-88 - 16 * max(0.0, -paw))
    pose("leg_front_lower.R", pitch=-24 + 10 * max(0.0, -paw))
    for side in "LR":
        pose(f"leg_hind_upper.{side}", pitch=-64)
        pose(f"leg_hind_lower.{side}", pitch=58)
        for seg in ("upper", "lower"):
            P[f"leg_hind_{seg}.{side}"].scale = (0.75, 0.75, 0.75)
    pose("tail0", pitch=-14, sway=8 * math.sin(t))
    pose("tail1", pitch=-8, sway=12 * math.sin(t))
    key_all(f)

# Roll: flop onto the side and paw at the caught thing, tail sweeping.
new_action("Roll", 60)
for f in range(1, 61, 3):
    t = (f - 1) / 59 * 2 * math.pi
    clear_pose()
    # roll onto the side but keep the face toward the camera: the head
    # counter-rotates against the body roll.
    pose("root", sway=46 + 3 * math.sin(t), worldz=-(spine_z - 0.26), pitch=4)
    pose("chest", sway=8)
    pose("neck", pitch=-4, sway=-22)
    pose("head", pitch=-2 + 3 * math.sin(t * 2), sway=-20)
    paw = math.sin(t * 2)
    pose("leg_front_upper.L", pitch=-62 - 14 * max(0.0, paw))
    pose("leg_front_lower.L", pitch=-16 + 10 * max(0.0, paw))
    pose("leg_front_upper.R", pitch=-62 - 14 * max(0.0, -paw))
    pose("leg_front_lower.R", pitch=-16 + 10 * max(0.0, -paw))
    kick = math.sin(t * 2 + 1.2)
    for side, sgn in (("L", 1), ("R", -1)):
        pose(f"leg_hind_upper.{side}", pitch=-34 - 8 * kick * sgn)
        pose(f"leg_hind_lower.{side}", pitch=28)
    pose("tail0", pitch=-10, sway=20 * math.sin(t * 1.3))
    pose("tail1", sway=26 * math.sin(t * 1.3 + 0.5))
    pose("tail2", sway=26 * math.sin(t * 1.3 + 1.0))
    key_all(f)

# Peer: crouched low, nose pointed down between the forepaws, head
# tilting curiously at something underneath her.
new_action("Peer", 48)
for f in range(1, 49, 3):
    t = (f - 1) / 47 * 2 * math.pi
    clear_pose()
    pose("root", worldz=-0.26 * spine_z, pitch=2)
    pose("chest", pitch=-6)
    pose("neck", pitch=-24)
    pose("head", pitch=-22 + 2 * math.sin(t * 2), sway=9 * math.sin(t))
    for side in "LR":
        pose(f"leg_front_upper.{side}", pitch=-8)
        pose(f"leg_front_lower.{side}", pitch=12)
        pose(f"leg_hind_upper.{side}", pitch=-24)
        pose(f"leg_hind_lower.{side}", pitch=28)
    pose("tail0", pitch=8)
    pose("tail2", sway=14 * math.sin(t * 1.6))
    pose("tail3", sway=18 * math.sin(t * 1.6 + 0.6))
    key_all(f)

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
    scn.display.shading.color_type = 'TEXTURE'
    scn.render.resolution_x = 640
    scn.render.resolution_y = 480
    scn.render.film_transparent = True
    bpy.ops.object.camera_add(location=(0.1, -3.6, 0.8),
                              rotation=(math.radians(86), 0, 0))
    scn.camera = bpy.context.object
    for name in ("Idle", "Walk", "Sit", "Lie", "Jump_Loop", "Idle_Eating"):
        for tr in arm_ob.animation_data.nla_tracks:
            tr.mute = tr.name != name
        frame = {"Idle": 1, "Walk": 7, "Sit": 49, "Lie": 49,
                 "Jump_Loop": 9, "Idle_Eating": 37}[name]
        scn.frame_set(frame)
        dg = bpy.context.evaluated_depsgraph_get()
        aeval = arm_ob.evaluated_get(dg)
        for bn in ("root", "chest", "leg_front_lower.L", "leg_hind_lower.L", "tail3"):
            wz = (aeval.matrix_world @ aeval.pose.bones[bn].tail).z
            print(f"POSEZ {name} {bn} tail_z={wz:.3f}")
        scn.render.filepath = f"{PREVIEW_DIR}/pose_{name}.png"
        bpy.ops.render.render(write_still=True)
    for tr in arm_ob.animation_data.nla_tracks:
        tr.mute = False

# -------------------------------------------------------------------- export
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format='GLB',
                          export_animations=True, export_apply=False,
                          export_image_format='JPEG',
                          export_yup=True)
print(f"RIG-CAT-DONE {OUT_GLB}")
