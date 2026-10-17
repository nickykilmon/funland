extends RefCounted
# Builds the maps out of simple shapes. Everything uses fixed random seeds so
# every player in the room gets exactly the same map.

const Figure = preload("res://scripts/figure.gd")

const NAMES := [
	"Plane", "House", "City", "Forest", "World", "Desert", "Snow", "Moon",
	"Castle", "Candy Land", "Volcano", "Sky Islands", "Stadium",
]

const TRUNK := Color(0.42, 0.26, 0.12)
const LEAF := Color(0.18, 0.55, 0.18)
const LEAF2 := Color(0.25, 0.65, 0.2)
const PINE := Color(0.1, 0.4, 0.2)

static var _stud_tex: Texture2D


static func spawn_point(id: int) -> Vector3:
	match id:
		1: return Vector3(0, 0.5, 4)
		8: return Vector3(0, 0.5, 12)
		_: return Vector3(0, 0.5, 0)


static func gravity(id: int) -> float:
	return 4.0 if id == 7 else 18.0


static func build(id: int, ground: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Map"
	match id:
		0:
			_env(root)
			_ground(root, ground, 160.0)
		1: _house_map(root, ground)
		2: _city(root)
		3: _forest(root)
		4: _island(root)
		5: _desert(root)
		6: _snow(root)
		7: _moon(root)
		8: _castle(root, ground)
		9: _candy(root)
		10: _volcano(root)
		11: _sky_islands(root)
		12: _stadium(root)
	return root


static func _env(root: Node3D, top := Color(0.22, 0.48, 0.95), horizon := Color(0.7, 0.84, 1.0),
		fog := 0.0, sun_color := Color.WHITE, sun_energy := 1.15, sun_pitch := -50.0) -> Environment:
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = top
	sm.sky_horizon_color = horizon
	sm.ground_horizon_color = horizon
	sm.ground_bottom_color = horizon.darkened(0.4)
	var sky := Sky.new()
	sky.sky_material = sm
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.ssao_enabled = true
	if fog > 0.0:
		env.fog_enabled = true
		env.fog_light_color = horizon
		env.fog_density = fog
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(sun_pitch, -35, 0)
	sun.light_color = sun_color
	sun.light_energy = sun_energy
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	root.add_child(sun)
	return env


# Baseplate-style material: tiles a little stud ring every 0.4 m so it lines up with funbricks.
static func stud_mat(c: Color) -> StandardMaterial3D:
	if _stud_tex == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
		for y in 64:
			for x in 64:
				var dist := Vector2(x - 31.5, y - 31.5).length()
				var v := 0.92
				if dist < 19.0:
					v = 1.0
				elif dist < 22.0:
					v = 0.78
				img.set_pixel(x, y, Color(v, v, v))
		img.generate_mipmaps()
		_stud_tex = ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.albedo_texture = _stud_tex
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(2.5, 2.5, 2.5)
	m.roughness = 0.45
	return m


static func solid(parent: Node, size: Vector3, pos: Vector3, c: Color, m: Material = null) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	sb.add_child(cs)
	var mi := Figure.box(sb, size, Vector3.ZERO, c)
	if m:
		mi.material_override = m
	parent.add_child(sb)
	return sb


static func cone(parent: Node, r_top: float, r_bottom: float, h: float, pos: Vector3, m: Material) -> StaticBody3D:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bottom
	cm.height = h
	cm.radial_segments = 48
	cm.rings = 1
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	cs.shape = cm.create_convex_shape()
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = m
	sb.add_child(mi)
	parent.add_child(sb)
	return sb


static func ball(parent: Node, r: float, pos: Vector3, c: Color, collide := true) -> Node3D:
	if not collide:
		return Figure.sphere(parent, r, pos, c)
	var sb := StaticBody3D.new()
	sb.position = pos
	var cs := CollisionShape3D.new()
	var ss := SphereShape3D.new()
	ss.radius = r
	cs.shape = ss
	sb.add_child(cs)
	Figure.sphere(sb, r, Vector3.ZERO, c)
	parent.add_child(sb)
	return sb


# A walkable slanted board from `from` (bottom) up to `to` (top).
static func ramp(parent: Node, from: Vector3, to: Vector3, width: float, c: Color) -> void:
	var mid := (from + to) * 0.5
	var flat := Vector2(to.x - from.x, to.z - from.z)
	var length := Vector3(to - from).length()
	var sb := solid(parent, Vector3(width, 0.2, length), mid, c)
	sb.rotation.y = atan2(-flat.x, -flat.y)
	sb.rotation.x = atan2(to.y - from.y, flat.length())


# Touching this sends the local player back to spawn.
static func kill_zone(parent: Node, size: Vector3, pos: Vector3) -> void:
	var area := Area3D.new()
	area.position = pos
	area.collision_layer = 0
	area.collision_mask = 2
	area.add_to_group("kill_zone")
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	area.add_child(cs)
	parent.add_child(area)


static func _water(root: Node3D, size: Vector2, pos: Vector3, c := Color(0.1, 0.45, 0.8, 0.75)) -> void:
	var water := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	water.mesh = pm
	var wm := StandardMaterial3D.new()
	wm.albedo_color = c
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.roughness = 0.05
	wm.metallic = 0.2
	water.material_override = wm
	water.position = pos
	root.add_child(water)


static func _ground(root: Node3D, c: Color, size: float) -> void:
	solid(root, Vector3(size, 1, size), Vector3(0, -0.5, 0), c, stud_mat(c))


static func _tree(root: Node3D, pos: Vector3, h: float, pine: bool, snowy := false) -> void:
	solid(root, Vector3(0.6, h, 0.6), pos + Vector3(0, h * 0.5, 0), TRUNK)
	if pine:
		for i in 4:
			var s := 3.4 - i * 0.75
			Figure.box(root, Vector3(s, 0.9, s), pos + Vector3(0, h - 0.6 + i * 0.9, 0), PINE)
			if snowy:
				Figure.box(root, Vector3(s * 0.8, 0.12, s * 0.8), pos + Vector3(0, h - 0.1 + i * 0.9, 0), Color.WHITE)
	else:
		Figure.box(root, Vector3(3.2, 2.4, 3.2), pos + Vector3(0, h + 0.8, 0), LEAF)
		Figure.box(root, Vector3(2.0, 1.0, 2.0), pos + Vector3(0, h + 2.5, 0), LEAF2)


static func _palm(root: Node3D, p: Vector3, yaw: float) -> void:
	var palm := Node3D.new()
	palm.position = p
	palm.rotation.y = yaw
	root.add_child(palm)
	for i in 6:
		solid(palm, Vector3(0.45, 0.8, 0.45), Vector3(i * 0.08, 0.4 + i * 0.8, 0), Color(0.6, 0.45, 0.25))
	for i in 5:
		var leaf := Figure.box(palm, Vector3(2.6, 0.08, 0.7), Vector3(0.4, 4.9, 0), Color(0.2, 0.6, 0.15))
		leaf.rotation = Vector3(0, TAU * i / 5.0, -0.3)
		leaf.position += Vector3(cos(TAU * i / 5.0), 0, -sin(TAU * i / 5.0)) * 1.0


# ---------------- original maps ----------------

static func _house_map(root: Node3D, ground: Color) -> void:
	_env(root)
	_ground(root, ground, 120.0)
	var wall := Color(0.95, 0.9, 0.8)
	var roof := Color(0.75, 0.15, 0.12)
	var glass := Color(0.45, 0.7, 0.95)
	var z0 := -12.0
	solid(root, Vector3(10, 0.04, 8), Vector3(0, 0.02, z0), Color(0.6, 0.38, 0.2))
	solid(root, Vector3(4.2, 3.5, 0.4), Vector3(-2.9, 1.75, z0 + 4), wall)
	solid(root, Vector3(4.2, 3.5, 0.4), Vector3(2.9, 1.75, z0 + 4), wall)
	solid(root, Vector3(1.6, 1.1, 0.4), Vector3(0, 2.95, z0 + 4), wall)
	solid(root, Vector3(10, 3.5, 0.4), Vector3(0, 1.75, z0 - 4), wall)
	solid(root, Vector3(0.4, 3.5, 7.6), Vector3(-4.8, 1.75, z0), wall)
	solid(root, Vector3(0.4, 3.5, 7.6), Vector3(4.8, 1.75, z0), wall)
	for x in [-2.9, 2.9]:
		Figure.box(root, Vector3(1.6, 1.1, 0.06), Vector3(x, 1.9, z0 + 4.22), glass)
	for x in [-5.02, 5.02]:
		Figure.box(root, Vector3(0.06, 1.1, 1.8), Vector3(x, 1.9, z0), glass)
	for side in [-1, 1]:
		var slab := solid(root, Vector3(10.8, 0.3, 5.2), Vector3(0, 5.12, z0 + 2.145 * side), roof)
		slab.rotation.x = 0.6 * side
	for x in [-4.8, 4.8]:
		var gable := MeshInstance3D.new()
		var pm := PrismMesh.new()
		pm.size = Vector3(8.0, 2.75, 0.4)
		gable.mesh = pm
		gable.material_override = Figure.mat(wall)
		gable.position = Vector3(x, 3.5 + 1.375, z0)
		gable.rotation.y = PI * 0.5
		root.add_child(gable)
	solid(root, Vector3(0.8, 2.2, 0.8), Vector3(2.6, 5.6, z0 - 1.5), Color(0.55, 0.25, 0.18))
	solid(root, Vector3(2.0, 0.1, 1.2), Vector3(0, 0.85, z0 - 1), Color(0.5, 0.3, 0.15))
	for lx in [-0.9, 0.9]:
		for lz in [-0.5, 0.5]:
			solid(root, Vector3(0.1, 0.8, 0.1), Vector3(lx, 0.4, z0 - 1 + lz), Color(0.5, 0.3, 0.15))
	Figure.box(root, Vector3(1.6, 0.02, 6), Vector3(0, 0.01, -5), Color(0.75, 0.72, 0.68))
	_tree(root, Vector3(-9, 0, -8), 3.0, false)
	_tree(root, Vector3(9, 0, -14), 3.5, false)
	_tree(root, Vector3(10, 0, -4), 3.0, true)


static func _city(root: Node3D) -> void:
	_env(root)
	solid(root, Vector3(200, 1, 200), Vector3(0, -0.5, 0), Color(0.22, 0.22, 0.24))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var palette := [
		Color(0.85, 0.82, 0.75), Color(0.7, 0.3, 0.25), Color(0.4, 0.55, 0.75), Color(0.9, 0.75, 0.4),
		Color(0.6, 0.6, 0.65), Color(0.35, 0.6, 0.45), Color(0.95, 0.95, 0.95),
	]
	var window := Color(0.15, 0.25, 0.4)
	for bx in range(-3, 4):
		for bz in range(-3, 4):
			var c := Vector3(bx * 26.0, 0, bz * 26.0)
			if bx == 0 and bz == 0:
				solid(root, Vector3(18, 0.08, 18), c + Vector3(0, 0.04, 0), Color(0.3, 0.65, 0.25), stud_mat(Color(0.3, 0.65, 0.25)))
				solid(root, Vector3(3, 0.6, 3), c + Vector3(0, 0.3, -6), Color(0.7, 0.7, 0.72))
				Figure.box(root, Vector3(2.6, 0.05, 2.6), c + Vector3(0, 0.6, -6), Color(0.3, 0.6, 0.95))
				continue
			solid(root, Vector3(18, 0.08, 18), c + Vector3(0, 0.04, 0), Color(0.65, 0.65, 0.66))
			var lots: Array = [Vector3.ZERO] if rng.randf() < 0.4 else [Vector3(-4, 0, -4), Vector3(4, 0, -4), Vector3(-4, 0, 4), Vector3(4, 0, 4)]
			var w := 14.0 if lots.size() == 1 else 6.5
			for lot in lots:
				var floors := rng.randi_range(2, 12 if lots.size() == 1 else 6)
				var h := floors * 3.0
				var col: Color = palette[rng.randi() % palette.size()]
				var pos: Vector3 = c + lot
				solid(root, Vector3(w, h, w), pos + Vector3(0, h * 0.5 + 0.08, 0), col)
				for f in floors:
					Figure.box(root, Vector3(w + 0.06, 1.1, w + 0.06), pos + Vector3(0, f * 3.0 + 1.9, 0), window)
				Figure.box(root, Vector3(w + 0.3, 0.3, w + 0.3), pos + Vector3(0, h + 0.2, 0), col.darkened(0.2))
	var yellow := Color(1.0, 0.85, 0.2)
	for line in [-78.0, -52.0, -26.0, 0.0, 26.0, 52.0, 78.0]:
		var r: float = line + 13.0
		for i in range(-22, 23):
			Figure.box(root, Vector3(0.2, 0.02, 2.0), Vector3(r, 0.01, i * 4.0), yellow)
			Figure.box(root, Vector3(2.0, 0.02, 0.2), Vector3(i * 4.0, 0.01, r), yellow)
	for i in 24:
		var road := (rng.randi_range(-4, 3) * 26.0) + 13.0
		var along := rng.randf_range(-80, 80)
		var horiz := rng.randf() < 0.5
		var p := Vector3(road + 2.5, 0, along) if not horiz else Vector3(along, 0, road + 2.5)
		_car(root, p, horiz, palette[rng.randi() % palette.size()])


static func _car(root: Node3D, p: Vector3, horiz: bool, col: Color) -> void:
	var car := Node3D.new()
	car.position = p
	if horiz:
		car.rotation.y = PI * 0.5
	root.add_child(car)
	solid(car, Vector3(1.8, 0.7, 3.8), Vector3(0, 0.6, 0), col)
	solid(car, Vector3(1.6, 0.6, 2.0), Vector3(0, 1.25, 0.2), col.lightened(0.15))
	Figure.box(car, Vector3(1.62, 0.4, 0.06), Vector3(0, 1.3, -0.82), Color(0.2, 0.3, 0.4))
	for wx in [-0.9, 0.9]:
		for wz in [-1.2, 1.2]:
			var wheel := Figure.cyl(car, 0.32, 0.25, Vector3(wx, 0.32, wz), Color(0.08, 0.08, 0.08))
			wheel.rotation.z = PI * 0.5


static func _forest(root: Node3D) -> void:
	_env(root, Color(0.22, 0.48, 0.95), Color(0.72, 0.84, 1.0), 0.006)
	var grass := Color(0.25, 0.52, 0.18)
	_ground(root, grass, 200.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for i in 260:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 10.0:
			continue
		_tree(root, p, rng.randf_range(2.5, 5.5), rng.randf() < 0.5)
	for i in 40:
		var p := Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-90, 90))
		var s := rng.randf_range(0.6, 2.0)
		solid(root, Vector3(s * 1.3, s, s), p + Vector3(0, s * 0.4, 0), Color(0.5, 0.5, 0.52))
	for i in 30:
		var p := Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-90, 90))
		Figure.cyl(root, 0.1, 0.4, p + Vector3(0, 0.2, 0), Color(0.95, 0.92, 0.85))
		Figure.cyl(root, 0.3, 0.15, p + Vector3(0, 0.45, 0), Color(0.85, 0.1, 0.1))
	solid(root, Vector3(3.0, 0.4, 0.5), Vector3(0, 0.2, -4), TRUNK)
	solid(root, Vector3(0.5, 0.4, 3.0), Vector3(-4, 0.2, 0), TRUNK)
	_campfire(root, Vector3(0, 0, 3))


static func _campfire(root: Node3D, p: Vector3) -> void:
	for i in 6:
		var a := TAU * i / 6.0
		Figure.box(root, Vector3(0.3, 0.25, 0.3), p + Vector3(cos(a) * 0.7, 0.12, sin(a) * 0.7), Color(0.5, 0.5, 0.5))
	var flame := Figure.cyl(root, 0.0, 0.7, p + Vector3(0, 0.35, 0), Color(1.0, 0.45, 0.05), 0.3)
	flame.material_override = Figure.glow_mat(Color(1.0, 0.45, 0.05))
	var fire := OmniLight3D.new()
	fire.position = p + Vector3(0, 1.0, 0)
	fire.light_color = Color(1.0, 0.6, 0.25)
	fire.light_energy = 2.0
	fire.omni_range = 8.0
	root.add_child(fire)


static func _island(root: Node3D) -> void:
	_env(root, Color(0.22, 0.48, 0.95), Color(0.72, 0.84, 1.0), 0.004)
	var sand := Color(0.93, 0.85, 0.6)
	var grass := Color(0.3, 0.68, 0.22)
	solid(root, Vector3(600, 1, 600), Vector3(0, -3.5, 0), sand.darkened(0.25))
	_water(root, Vector2(600, 600), Vector3(0, -0.35, 0))
	cone(root, 42.0, 62.0, 3.0, Vector3(0, -1.5, 0), Figure.mat(sand))
	cone(root, 34.0, 38.0, 0.6, Vector3(0, -0.27, 0), stud_mat(grass))
	cone(root, 3.0, 14.0, 5.0, Vector3(14, 2.5, 12), stud_mat(grass))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in 22:
		var a := rng.randf() * TAU
		var r := rng.randf_range(8.0, 30.0)
		var p := Vector3(cos(a) * r, 0, sin(a) * r)
		if p.distance_to(Vector3(14, 0, 12)) < 15.0 or p.length() < 6.0:
			continue
		_tree(root, p, rng.randf_range(2.5, 4.5), rng.randf() < 0.3)
	for i in 14:
		var a := rng.randf() * TAU
		var r := rng.randf_range(36.0, 41.0)
		_palm(root, Vector3(cos(a) * r, 0, sin(a) * r), rng.randf() * TAU)
	var wood := Color(0.55, 0.38, 0.2)
	solid(root, Vector3(3, 0.12, 18), Vector3(0, 0.0, 50), wood)
	for z in [43.0, 49.0, 55.0]:
		for x in [-1.4, 1.4]:
			solid(root, Vector3(0.3, 3.0, 0.3), Vector3(x, -1.5, z), wood)


# ---------------- new maps ----------------

static func _desert(root: Node3D) -> void:
	_env(root, Color(0.35, 0.6, 0.95), Color(0.95, 0.85, 0.65), 0.005, Color(1.0, 0.93, 0.8), 1.3)
	var sand := Color(0.92, 0.8, 0.52)
	_ground(root, sand, 220.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55
	# dunes
	for i in 18:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 25.0:
			continue
		var r := rng.randf_range(8, 16)
		var h := rng.randf_range(1.5, 4.0)
		cone(root, r * 0.2, r, h, p + Vector3(0, h * 0.5, 0), stud_mat(sand.darkened(0.05)))
	# pyramids
	for pyr in [[Vector3(0, 0, -45), 14], [Vector3(-30, 0, -60), 10], [Vector3(28, 0, -62), 8]]:
		var base: Vector3 = pyr[0]
		var steps: int = pyr[1]
		for s in steps:
			var size := (steps - s) * 2.2
			solid(root, Vector3(size, 1.0, size), base + Vector3(0, s + 0.5, 0), Color(0.88, 0.75, 0.45).darkened(s * 0.01))
	# cacti
	var green := Color(0.25, 0.55, 0.25)
	for i in 35:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 8.0 or p.distance_to(Vector3(0, 0, -45)) < 18.0:
			continue
		var h := rng.randf_range(2.0, 4.0)
		solid(root, Vector3(0.5, h, 0.5), p + Vector3(0, h * 0.5, 0), green)
		for side in [-1, 1]:
			if rng.randf() < 0.7:
				var ah := h * rng.randf_range(0.4, 0.7)
				Figure.box(root, Vector3(0.6, 0.35, 0.35), p + Vector3(0.45 * side, ah, 0), green)
				Figure.box(root, Vector3(0.35, 0.9, 0.35), p + Vector3(0.7 * side, ah + 0.45, 0), green)
	# oasis
	var oasis := Vector3(30, 0, 20)
	Figure.cyl(root, 7.0, 0.04, oasis + Vector3(0, 0.02, 0), Color(0.2, 0.55, 0.85))
	for i in 6:
		var a := TAU * i / 6.0
		_palm(root, oasis + Vector3(cos(a) * 9.0, 0, sin(a) * 9.0), a)
	# ruins
	for i in 6:
		var h := rng.randf_range(1.5, 5.0)
		solid(root, Vector3(1.0, h, 1.0), Vector3(-30 + i * 3.0, h * 0.5, 15), Color(0.85, 0.78, 0.6))


static func _snow(root: Node3D) -> void:
	_env(root, Color(0.5, 0.65, 0.85), Color(0.88, 0.92, 0.98), 0.012, Color(0.95, 0.97, 1.0), 0.9)
	var snow := Color(0.95, 0.97, 1.0)
	_ground(root, snow, 220.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 909
	for i in 140:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 12.0:
			continue
		_tree(root, p, rng.randf_range(2.5, 5.0), true, true)
	# mountains around the edge
	for i in 14:
		var a := TAU * i / 14.0
		var r := rng.randf_range(16, 30)
		var h := rng.randf_range(15, 35)
		var p := Vector3(cos(a) * 105.0, h * 0.5, sin(a) * 105.0)
		cone(root, 0.5, r, h, p, Figure.mat(Color(0.7, 0.72, 0.78)))
		Figure.cyl(root, 0.5, h * 0.35, p + Vector3(0, h * 0.325, 0), snow, r * 0.35)
	# frozen lake
	Figure.cyl(root, 14.0, 0.04, Vector3(-30, 0.02, -20), Color(0.65, 0.85, 0.95))
	# igloo
	var igloo := MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 3.0
	dome.height = 3.0
	dome.is_hemisphere = true
	igloo.mesh = dome
	igloo.material_override = Figure.mat(Color(0.92, 0.95, 1.0))
	var igloo_body := StaticBody3D.new()
	igloo_body.position = Vector3(15, 0, -10)
	var ics := CollisionShape3D.new()
	ics.shape = dome.create_convex_shape()
	igloo_body.add_child(ics)
	igloo_body.add_child(igloo)
	root.add_child(igloo_body)
	Figure.box(root, Vector3(1.4, 1.4, 0.1), Vector3(15, 0.7, -7.05), Color(0.15, 0.2, 0.3))
	# snowmen
	for p in [Vector3(-6, 0, -6), Vector3(8, 0, 6)]:
		ball(root, 0.9, p + Vector3(0, 0.8, 0), snow)
		ball(root, 0.65, p + Vector3(0, 2.1, 0), snow)
		ball(root, 0.45, p + Vector3(0, 3.05, 0), snow)
		Figure.cyl(root, 0.0, 0.4, p + Vector3(0, 3.05, -0.6), Color(1.0, 0.5, 0.1), 0.07).rotation.x = -PI * 0.5
		for x in [-0.15, 0.15]:
			Figure.box(root, Vector3(0.08, 0.08, 0.05), p + Vector3(x, 3.2, -0.42), Figure.BLACK)
		Figure.cyl(root, 0.3, 0.4, p + Vector3(0, 3.6, 0), Figure.BLACK)
	_campfire(root, Vector3(0, 0, -8))
	_snowfall(root)


static func _snowfall(root: Node3D) -> void:
	var p := GPUParticles3D.new()
	p.amount = 3000
	p.lifetime = 12.0
	p.preprocess = 12.0
	p.visibility_aabb = AABB(Vector3(-100, -30, -100), Vector3(200, 60, 200))
	p.position = Vector3(0, 25, 0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(100, 1, 100)
	pm.gravity = Vector3(0.4, -2.2, 0)
	pm.direction = Vector3(0, -1, 0)
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 0.8
	pm.turbulence_enabled = true
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.12, 0.12)
	var qm := StandardMaterial3D.new()
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.albedo_color = Color.WHITE
	q.material = qm
	p.draw_pass_1 = q
	root.add_child(p)


static func _moon(root: Node3D) -> void:
	_env(root, Color(0.0, 0.0, 0.02), Color(0.03, 0.03, 0.06), 0.0, Color(1.0, 1.0, 0.97), 1.4, -35.0)
	var dust := Color(0.62, 0.62, 0.64)
	_ground(root, dust, 220.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1969
	# craters: dark floor with a raised rim
	for i in 25:
		var p := Vector3(rng.randf_range(-90, 90), 0, rng.randf_range(-90, 90))
		if p.length() < 12.0:
			continue
		var r := rng.randf_range(3, 10)
		Figure.cyl(root, r, 0.03, p + Vector3(0, 0.015, 0), dust.darkened(0.2))
		var rim := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = r
		tm.outer_radius = r + 1.2
		rim.mesh = tm
		rim.scale = Vector3(1, 0.5, 1)
		rim.material_override = Figure.mat(dust.lightened(0.05))
		rim.position = p
		root.add_child(rim)
	for i in 50:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		var s := rng.randf_range(0.3, 1.5)
		solid(root, Vector3(s * 1.2, s * 0.7, s), p + Vector3(0, s * 0.3, 0), dust.darkened(0.15))
	# lunar lander
	var lander := Vector3(10, 0, -10)
	solid(root, Vector3(3, 2, 3), lander + Vector3(0, 2.5, 0), Color(0.85, 0.7, 0.2))
	solid(root, Vector3(2.2, 1.6, 2.2), lander + Vector3(0, 4.3, 0), Color(0.8, 0.8, 0.82))
	for x in [-1.8, 1.8]:
		for z in [-1.8, 1.8]:
			Figure.box(root, Vector3(0.15, 2.0, 0.15), lander + Vector3(x, 1.0, z), Color(0.7, 0.7, 0.7))
			Figure.cyl(root, 0.4, 0.08, lander + Vector3(x, 0.04, z), Color(0.7, 0.7, 0.7))
	# flag
	Figure.cyl(root, 0.04, 3.0, Vector3(5, 1.5, -6), Color(0.85, 0.85, 0.85))
	Figure.box(root, Vector3(1.4, 0.9, 0.02), Vector3(5.72, 2.5, -6), Color(0.9, 0.2, 0.2))
	# earth in the sky + stars
	var earth := Figure.sphere(root, 25.0, Vector3(-150, 120, -250), Color(0.2, 0.45, 0.9))
	earth.material_override = Figure.glow_mat(Color(0.2, 0.45, 0.9))
	var stars := MultiMesh.new()
	stars.transform_format = MultiMesh.TRANSFORM_3D
	var sm := SphereMesh.new()
	sm.radius = 0.6
	sm.height = 1.2
	sm.radial_segments = 6
	sm.rings = 3
	sm.material = Figure.glow_mat(Color.WHITE)
	stars.mesh = sm
	stars.instance_count = 600
	for i in 600:
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.05, 1), rng.randf_range(-1, 1)).normalized()
		stars.set_instance_transform(i, Transform3D(Basis(), dir * 350.0))
	var smi := MultiMeshInstance3D.new()
	smi.multimesh = stars
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(smi)


static func _castle(root: Node3D, ground: Color) -> void:
	_env(root)
	_ground(root, ground, 180.0)
	var stone := Color(0.62, 0.6, 0.58)
	var c := Vector3(0, 0, -25)
	var half := 15.0
	var wall_h := 6.0
	# moat
	for side in [-1, 1]:
		Figure.box(root, Vector3(half * 2 + 12, 0.03, 3), c + Vector3(0, 0.015, (half + 3.5) * side), Color(0.2, 0.45, 0.75))
		Figure.box(root, Vector3(3, 0.03, half * 2 + 12), c + Vector3((half + 3.5) * side, 0.015, 0), Color(0.2, 0.45, 0.75))
	# bridge over the moat to the gate
	solid(root, Vector3(4, 0.06, 5), c + Vector3(0, 0.03, half + 3.5), Color(0.5, 0.33, 0.18))
	# walls with a gate in the front
	solid(root, Vector3(half * 2, wall_h, 1.2), c + Vector3(0, wall_h * 0.5, -half), stone)
	solid(root, Vector3(1.2, wall_h, half * 2), c + Vector3(-half, wall_h * 0.5, 0), stone)
	solid(root, Vector3(1.2, wall_h, half * 2), c + Vector3(half, wall_h * 0.5, 0), stone)
	solid(root, Vector3(half - 2.5, wall_h, 1.2), c + Vector3(-(half + 2.5) * 0.5, wall_h * 0.5, half), stone)
	solid(root, Vector3(half - 2.5, wall_h, 1.2), c + Vector3((half + 2.5) * 0.5, wall_h * 0.5, half), stone)
	solid(root, Vector3(5, 2, 1.2), c + Vector3(0, wall_h - 1, half), stone)
	# battlements
	for i in range(-7, 8):
		for side in [-1, 1]:
			Figure.box(root, Vector3(0.9, 0.8, 0.4), c + Vector3(i * 2.0, wall_h + 0.4, half * side + 0.4 * side), stone)
			Figure.box(root, Vector3(0.4, 0.8, 0.9), c + Vector3(half * side + 0.4 * side, wall_h + 0.4, i * 2.0), stone)
	# walkway ramps up to the wall tops
	ramp(root, c + Vector3(-half + 2.0, 0, 6), c + Vector3(-half + 2.0, wall_h, -8), 2.5, Color(0.5, 0.48, 0.46))
	ramp(root, c + Vector3(half - 2.0, 0, 6), c + Vector3(half - 2.0, wall_h, -8), 2.5, Color(0.5, 0.48, 0.46))
	solid(root, Vector3(2.5, 0.2, 7), c + Vector3(-half + 2.0, wall_h - 0.1, -11.5), Color(0.5, 0.48, 0.46))
	solid(root, Vector3(2.5, 0.2, 7), c + Vector3(half - 2.0, wall_h - 0.1, -11.5), Color(0.5, 0.48, 0.46))
	# corner towers with pointy roofs
	for x in [-1, 1]:
		for z in [-1, 1]:
			var tp := c + Vector3(half * x, 0, half * z)
			var tower := StaticBody3D.new()
			tower.position = tp + Vector3(0, 5, 0)
			var tcs := CollisionShape3D.new()
			var cyl_shape := CylinderShape3D.new()
			cyl_shape.radius = 2.5
			cyl_shape.height = 10
			tcs.shape = cyl_shape
			tower.add_child(tcs)
			Figure.cyl(tower, 2.5, 10, Vector3.ZERO, stone)
			root.add_child(tower)
			Figure.cyl(root, 0.0, 4.0, tp + Vector3(0, 12, 0), Color(0.2, 0.25, 0.65), 3.0)
			Figure.cyl(root, 0.03, 1.5, tp + Vector3(0, 14.6, 0), Color(0.3, 0.3, 0.3))
			Figure.box(root, Vector3(0.8, 0.5, 0.02), tp + Vector3(0.4, 15.0, 0), Color(0.9, 0.15, 0.15))
	# keep
	solid(root, Vector3(9, 10, 8), c + Vector3(0, 5, -7), stone.darkened(0.05))
	solid(root, Vector3(2.4, 3.2, 0.2), c + Vector3(0, 1.6, -2.95), Color(0.35, 0.2, 0.1))
	for i in range(-2, 3):
		Figure.box(root, Vector3(1.0, 0.8, 1.0), c + Vector3(i * 2.0, 10.4, -3.4), stone)
	_tree(root, Vector3(-25, 0, 10), 3.5, false)
	_tree(root, Vector3(24, 0, 12), 3.0, false)


static func _candy(root: Node3D) -> void:
	_env(root, Color(0.6, 0.55, 0.95), Color(1.0, 0.8, 0.9), 0.004, Color(1.0, 0.95, 0.95))
	_ground(root, Color(1.0, 0.7, 0.82), 200.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	var candy := [Color(1.0, 0.3, 0.4), Color(0.4, 0.8, 1.0), Color(0.6, 1.0, 0.5), Color(1.0, 0.9, 0.3), Color(0.8, 0.5, 1.0), Color(1.0, 0.6, 0.2)]
	# chocolate river
	Figure.box(root, Vector3(8, 0.04, 200), Vector3(-25, 0.02, 0), Color(0.4, 0.22, 0.1))
	solid(root, Vector3(3, 0.1, 10), Vector3(-25, 0.05, 0), Color(1.0, 0.95, 0.9))
	for i in 70:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 10.0 or absf(p.x + 25.0) < 6.0:
			continue
		var col: Color = candy[rng.randi() % candy.size()]
		match rng.randi() % 5:
			0: # lollipop
				var h := rng.randf_range(2.5, 5.0)
				solid(root, Vector3(0.2, h, 0.2), p + Vector3(0, h * 0.5, 0), Color.WHITE)
				var pop := Figure.cyl(root, 1.0, 0.3, p + Vector3(0, h + 0.8, 0), col)
				pop.rotation.x = PI * 0.5
				Figure.cyl(root, 0.55, 0.32, p + Vector3(0, h + 0.8, 0), Color.WHITE).rotation.x = PI * 0.5
			1: # gumdrop
				var r := rng.randf_range(1.0, 2.0)
				cone(root, r * 0.4, r, r * 1.2, p + Vector3(0, r * 0.6, 0), Figure.mat(col))
			2: # candy cane
				for s in 8:
					solid(root, Vector3(0.4, 0.5, 0.4), p + Vector3(0, s * 0.5 + 0.25, 0), Color(0.9, 0.1, 0.1) if s % 2 == 0 else Color.WHITE)
				Figure.box(root, Vector3(1.2, 0.4, 0.4), p + Vector3(0.4, 4.2, 0), Color(0.9, 0.1, 0.1))
				Figure.box(root, Vector3(0.4, 0.8, 0.4), p + Vector3(0.8, 3.8, 0), Color.WHITE)
			3: # cupcake
				solid(root, Vector3(2.0, 1.4, 2.0), p + Vector3(0, 0.7, 0), Color(0.85, 0.6, 0.35))
				ball(root, 1.2, p + Vector3(0, 1.7, 0), col.lightened(0.4))
				Figure.sphere(root, 0.25, p + Vector3(0, 2.95, 0), Color(0.85, 0.05, 0.1))
			4: # cotton candy tree
				solid(root, Vector3(0.25, 3.0, 0.25), p + Vector3(0, 1.5, 0), Color.WHITE)
				Figure.sphere(root, 1.6, p + Vector3(0, 3.8, 0), col.lightened(0.5))
	# gingerbread house
	var g := Vector3(15, 0, -15)
	var ginger := Color(0.7, 0.42, 0.2)
	solid(root, Vector3(6, 4, 0.4), g + Vector3(0, 2, -3), ginger)
	solid(root, Vector3(0.4, 4, 6), g + Vector3(-3, 2, 0), ginger)
	solid(root, Vector3(0.4, 4, 6), g + Vector3(3, 2, 0), ginger)
	solid(root, Vector3(2, 4, 0.4), g + Vector3(-2, 2, 3), ginger)
	solid(root, Vector3(2, 4, 0.4), g + Vector3(2, 2, 3), ginger)
	for side in [-1, 1]:
		var slab := solid(root, Vector3(6.6, 0.3, 4.3), g + Vector3(0, 5.2, 1.7 * side), Color.WHITE)
		slab.rotation.x = 0.6 * side


static func _volcano(root: Node3D) -> void:
	var env := _env(root, Color(0.25, 0.08, 0.05), Color(0.65, 0.3, 0.15), 0.01, Color(1.0, 0.6, 0.4), 0.9)
	env.glow_intensity = 1.2
	var rock := Color(0.2, 0.18, 0.17)
	_ground(root, rock, 220.0)
	var lava := Color(1.0, 0.4, 0.05)
	var lava_mat := Figure.glow_mat(lava)
	# the volcano
	var vp := Vector3(0, 0, -75)
	cone(root, 12.0, 50.0, 30.0, vp + Vector3(0, 15, 0), Figure.mat(Color(0.28, 0.22, 0.2)))
	var crater := Figure.cyl(root, 10.0, 0.2, vp + Vector3(0, 30.05, 0), lava)
	crater.material_override = lava_mat
	var glow := OmniLight3D.new()
	glow.position = vp + Vector3(0, 34, 0)
	glow.light_color = lava
	glow.light_energy = 6.0
	glow.omni_range = 40.0
	root.add_child(glow)
	kill_zone(root, Vector3(20, 2, 20), vp + Vector3(0, 30.5, 0))
	# lava rivers and pools (deadly!)
	var rng := RandomNumberGenerator.new()
	rng.seed = 666
	var river := Figure.box(root, Vector3(4, 0.05, 60), Vector3(-8, 0.025, -20), lava)
	river.material_override = lava_mat
	kill_zone(root, Vector3(4, 1, 60), Vector3(-8, 0.3, -20))
	for i in 10:
		var p := Vector3(rng.randf_range(-80, 80), 0, rng.randf_range(-60, 80))
		if p.length() < 12.0 or absf(p.x + 8.0) < 6.0:
			continue
		var r := rng.randf_range(2, 5)
		Figure.cyl(root, r, 0.05, p + Vector3(0, 0.025, 0), lava).material_override = lava_mat
		kill_zone(root, Vector3(r * 1.4, 1, r * 1.4), p + Vector3(0, 0.3, 0))
	# rocks and dead trees
	for i in 60:
		var p := Vector3(rng.randf_range(-95, 95), 0, rng.randf_range(-95, 95))
		if p.length() < 8.0:
			continue
		if rng.randf() < 0.7:
			var s := rng.randf_range(0.5, 2.5)
			solid(root, Vector3(s, s * 0.8, s * 1.2), p + Vector3(0, s * 0.35, 0), rock.lightened(rng.randf() * 0.15))
		else:
			var h := rng.randf_range(2, 4)
			solid(root, Vector3(0.35, h, 0.35), p + Vector3(0, h * 0.5, 0), Color(0.15, 0.1, 0.08))
			Figure.box(root, Vector3(1.2, 0.2, 0.2), p + Vector3(0.4, h * 0.7, 0), Color(0.15, 0.1, 0.08)).rotation.z = 0.5
	# a safe bridge over the river
	solid(root, Vector3(6, 0.3, 3), Vector3(-8, 0.15, 0), Color(0.4, 0.4, 0.42))


static func _sky_islands(root: Node3D) -> void:
	_env(root, Color(0.25, 0.55, 1.0), Color(0.8, 0.9, 1.0), 0.0)
	var grass := Color(0.35, 0.72, 0.28)
	var dirt := Color(0.5, 0.35, 0.2)
	var islands := [
		[Vector3(0, 0, 0), 14.0], [Vector3(36, 6, -10), 9.0], [Vector3(-30, -4, -22), 10.0],
		[Vector3(8, 12, -45), 8.0], [Vector3(-12, 3, 38), 11.0], [Vector3(45, -2, 30), 7.0],
	]
	for isl in islands:
		var p: Vector3 = isl[0]
		var r: float = isl[1]
		cone(root, r, r * 0.3, r * 0.8, p + Vector3(0, -r * 0.4 - 0.5, 0), Figure.mat(dirt))
		cone(root, r, r, 1.0, p + Vector3(0, -0.5, 0), stud_mat(grass))
		_tree(root, p + Vector3(r * 0.4, 0, -r * 0.3), 3.0, false)
	# bridges between islands
	var wood := Color(0.6, 0.42, 0.22)
	for pair in [[0, 1], [0, 2], [1, 3], [0, 4], [1, 5]]:
		var a: Vector3 = islands[pair[0]][0]
		var b: Vector3 = islands[pair[1]][0]
		var dir := (b - a)
		var flat := Vector3(dir.x, 0, dir.z).normalized()
		var from: Vector3 = a + flat * (islands[pair[0]][1] - 1.0)
		var to: Vector3 = b - flat * (islands[pair[1]][1] - 1.0)
		ramp(root, from, to, 2.0, wood)
	# waterfall off the main island
	var fall := Figure.box(root, Vector3(3, 30, 0.3), Vector3(0, -15, 13.6), Color(0.6, 0.85, 1.0))
	fall.material_override = Figure.glass_mat(Color(0.6, 0.85, 1.0, 0.6))
	# clouds
	var rng := RandomNumberGenerator.new()
	rng.seed = 8080
	for i in 40:
		var p := Vector3(rng.randf_range(-120, 120), rng.randf_range(-30, 25), rng.randf_range(-120, 120))
		if p.length() < 25.0:
			continue
		for j in 3:
			Figure.sphere(root, rng.randf_range(2.5, 4.5), p + Vector3(j * 3.0, rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1)), Color(1, 1, 1))


static func _stadium(root: Node3D) -> void:
	_env(root)
	_ground(root, Color(0.3, 0.55, 0.25), 200.0)
	var line := Color(0.95, 0.95, 0.95)
	var fw := 34.0
	var fl := 54.0
	Figure.box(root, Vector3(fw * 2, 0.02, fl * 2), Vector3(0, 0.01, 0), Color(0.25, 0.6, 0.22))
	for i in range(-5, 6):
		if i % 2 == 0:
			Figure.box(root, Vector3(fw * 2, 0.025, fl * 2 / 11.0), Vector3(0, 0.012, i * fl * 2 / 11.0), Color(0.3, 0.68, 0.26))
	for side in [-1, 1]:
		Figure.box(root, Vector3(0.2, 0.03, fl * 2), Vector3(fw * side, 0.02, 0), line)
		Figure.box(root, Vector3(fw * 2, 0.03, 0.2), Vector3(0, 0.02, fl * side), line)
		Figure.box(root, Vector3(16, 0.03, 0.2), Vector3(0, 0.02, (fl - 8) * side), line)
		Figure.box(root, Vector3(0.2, 0.03, 8), Vector3(8 * (side), 0.02, (fl - 4) * 1), line)
		Figure.box(root, Vector3(0.2, 0.03, 8), Vector3(8 * (side), 0.02, -(fl - 4)), line)
		# goals
		var gz: float = fl * side
		for x in [-3.6, 3.6]:
			solid(root, Vector3(0.15, 2.4, 0.15), Vector3(x, 1.2, gz), line)
		solid(root, Vector3(7.35, 0.15, 0.15), Vector3(0, 2.4, gz), line)
		var net := Figure.box(root, Vector3(7.2, 2.4, 0.02), Vector3(0, 1.2, gz + 1.5 * side), Color(1, 1, 1, 0.4))
		net.material_override = Figure.glass_mat(Color(1, 1, 1, 0.35))
	Figure.box(root, Vector3(fw * 2, 0.03, 0.2), Vector3(0, 0.02, 0), line)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 8.0
	tm.outer_radius = 8.2
	ring.mesh = tm
	ring.scale = Vector3(1, 0.05, 1)
	ring.material_override = Figure.mat(line)
	root.add_child(ring)
	# stands
	var seats := [Color(0.85, 0.15, 0.15), Color(0.15, 0.35, 0.85)]
	for side in [-1, 1]:
		for row in 8:
			var col: Color = seats[(row / 2) % 2]
			solid(root, Vector3(1.2, 0.6 * (row + 1), fl * 2 + 10), Vector3((fw + 4 + row * 1.2) * side, 0.3 * (row + 1), 0), col)
			solid(root, Vector3(fw * 2 + 10, 0.6 * (row + 1), 1.2), Vector3(0, 0.3 * (row + 1), (fl + 4 + row * 1.2) * side), col)
	# floodlights
	for x in [-1, 1]:
		for z in [-1, 1]:
			var p := Vector3((fw + 16) * x, 0, (fl + 16) * z)
			solid(root, Vector3(0.6, 20, 0.6), p + Vector3(0, 10, 0), Color(0.5, 0.5, 0.52))
			var lamp := Figure.box(root, Vector3(4, 2, 0.4), p + Vector3(0, 20.5, 0), Color(1, 1, 0.9))
			lamp.material_override = Figure.glow_mat(Color(1, 1, 0.9))
			lamp.rotation.y = atan2(p.x, p.z)
	ball(root, 0.8, Vector3(0, 0.8, -6), Color.WHITE)
