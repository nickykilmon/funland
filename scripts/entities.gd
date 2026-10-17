extends RefCounted
# Catalog of physics props and vehicles you can spawn (B menu), and how to build each one.
# Wheels are listed as suspension mount points; "seat" is where the driver's feet go.

const Figure = preload("res://scripts/figure.gd")

enum { ITEM, CAR, HELI, PLANE, BOAT }

const DODGEBALL_TYPE := 4
const BUTTON := 22
const PLATE := 23
const LAMP := 24
const CHECKPOINT := 25
const BALLOON_COLORS := [Color(1, 0.2, 0.25), Color(0.25, 0.55, 1), Color(1, 0.85, 0.15), Color(0.4, 0.9, 0.35), Color(0.9, 0.4, 1), Color(1, 0.55, 0.15)]

const TYPES := [
	{"name": "Crate", "kind": ITEM, "mass": 20.0},
	{"name": "Small Crate", "kind": ITEM, "mass": 8.0},
	{"name": "Barrel", "kind": ITEM, "mass": 25.0},
	{"name": "Beach Ball", "kind": ITEM, "mass": 0.5, "bounce": 0.8},
	{"name": "Dodgeball", "kind": ITEM, "mass": 0.6, "bounce": 0.5},
	{"name": "Traffic Cone", "kind": ITEM, "mass": 3.0},
	{"name": "Chair", "kind": ITEM, "mass": 6.0},
	{"name": "Table", "kind": ITEM, "mass": 15.0},
	{"name": "Ramp", "kind": ITEM, "mass": 60.0},
	{"name": "Tire", "kind": ITEM, "mass": 10.0, "bounce": 0.4},
	{"name": "Watermelon", "kind": ITEM, "mass": 5.0},
	{"name": "Bowling Pin", "kind": ITEM, "mass": 2.0},
	{"name": "Soccer Ball", "kind": ITEM, "mass": 0.5, "bounce": 0.6},
	{"name": "Car", "kind": CAR, "mass": 900.0, "accel": 14.0, "top": 30.0, "steer": 0.5, "wheel_r": 0.35, "rest": 0.45,
		"wheels": [Vector3(-0.85, 0.5, -1.3), Vector3(0.85, 0.5, -1.3), Vector3(-0.85, 0.5, 1.3), Vector3(0.85, 0.5, 1.3)],
		"seat": Vector3(-0.35, 0.45, 0.2), "cam": 7.0, "com_y": 0.1},
	{"name": "Truck", "kind": CAR, "mass": 1800.0, "accel": 9.0, "top": 24.0, "steer": 0.45, "wheel_r": 0.45, "rest": 0.5,
		"wheels": [Vector3(-1.0, 0.6, -1.9), Vector3(1.0, 0.6, -1.9), Vector3(-1.0, 0.6, 1.7), Vector3(1.0, 0.6, 1.7)],
		"seat": Vector3(-0.4, 0.9, -1.6), "cam": 9.0, "com_y": 0.2},
	{"name": "Go-Kart", "kind": CAR, "mass": 200.0, "accel": 16.0, "top": 22.0, "steer": 0.6, "wheel_r": 0.22, "rest": 0.25,
		"wheels": [Vector3(-0.6, 0.3, -0.75), Vector3(0.6, 0.3, -0.75), Vector3(-0.6, 0.3, 0.75), Vector3(0.6, 0.3, 0.75)],
		"seat": Vector3(0, 0.15, 0.25), "cam": 5.0, "com_y": -0.05},
	{"name": "Monster Truck", "kind": CAR, "mass": 1500.0, "accel": 13.0, "top": 26.0, "steer": 0.5, "wheel_r": 0.8, "rest": 0.8,
		"wheels": [Vector3(-1.3, 1.2, -1.5), Vector3(1.3, 1.2, -1.5), Vector3(-1.3, 1.2, 1.5), Vector3(1.3, 1.2, 1.5)],
		"seat": Vector3(-0.35, 1.45, -0.2), "cam": 9.0, "com_y": 0.4},
	{"name": "Helicopter", "kind": HELI, "mass": 1200.0, "wheel_r": 0.1, "rest": 0.3,
		"wheels": [Vector3(-0.9, 0.3, -1.0), Vector3(0.9, 0.3, -1.0), Vector3(-0.9, 0.3, 1.0), Vector3(0.9, 0.3, 1.0)],
		"seat": Vector3(0, 0.55, -0.6), "cam": 11.0, "com_y": 0.6},
	{"name": "Plane", "kind": PLANE, "mass": 1000.0, "wheel_r": 0.3, "rest": 0.5, "steer": 0.4,
		"wheels": [Vector3(0, 0.6, -2.4), Vector3(-1.2, 0.6, 0.5), Vector3(1.2, 0.6, 0.5)],
		"seat": Vector3(0, 0.75, -0.6), "cam": 12.0, "com_y": 0.9},
	{"name": "TNT", "kind": ITEM, "mass": 10.0, "explosive": true},
	{"name": "Explosive Barrel", "kind": ITEM, "mass": 20.0, "explosive": true},
	{"name": "Boat", "kind": BOAT, "mass": 500.0, "seat": Vector3(0, 0.35, 1.0), "cam": 8.0, "com_y": -0.3},
	{"name": "Button", "kind": ITEM, "mass": 5.0, "frozen": true, "rest_y": 0.65},
	{"name": "Pressure Plate", "kind": ITEM, "mass": 10.0, "frozen": true, "rest_y": 0.05},
	{"name": "Lamp", "kind": ITEM, "mass": 8.0},
	{"name": "Checkpoint", "kind": ITEM, "mass": 50.0, "frozen": true, "rest_y": 0.3},
]


static func is_vehicle(type: int) -> bool:
	return TYPES[type]["kind"] != ITEM


static func _shape(body: Node3D, shape: Shape3D, pos := Vector3.ZERO, rot := Vector3.ZERO) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	cs.rotation = rot
	body.add_child(cs)


static func _box_shape(body: Node3D, size: Vector3, pos := Vector3.ZERO) -> void:
	var bs := BoxShape3D.new()
	bs.size = size
	_shape(body, bs, pos)


static func _sphere_shape(body: Node3D, r: float, pos := Vector3.ZERO) -> void:
	var ss := SphereShape3D.new()
	ss.radius = r
	_shape(body, ss, pos)


static func _cyl_shape(body: Node3D, r: float, h: float, pos := Vector3.ZERO, rot := Vector3.ZERO) -> void:
	var cs := CylinderShape3D.new()
	cs.radius = r
	cs.height = h
	_shape(body, cs, pos, rot)


# Adds the meshes and collision shapes for this type to the body. Items are centered on their middle.
static func dress(body: RigidBody3D, type: int) -> void:
	var t: Dictionary = TYPES[type]
	if t.has("bounce"):
		var pm := PhysicsMaterial.new()
		pm.bounce = t["bounce"]
		pm.friction = 0.6
		body.physics_material_override = pm
	match type:
		0, 1:
			var s := 1.0 if type == 0 else 0.6
			var wood := Color(0.62, 0.42, 0.22)
			Figure.box(body, Vector3(s, s, s), Vector3.ZERO, wood)
			for side in [-1, 1]:
				Figure.box(body, Vector3(s + 0.02, s * 0.15, s * 0.15), Vector3(0, s * 0.42 * side, s * 0.43), wood.darkened(0.25))
				Figure.box(body, Vector3(s + 0.02, s * 0.15, s * 0.15), Vector3(0, s * 0.42 * side, -s * 0.43), wood.darkened(0.25))
			_box_shape(body, Vector3(s, s, s))
		2:
			Figure.cyl(body, 0.4, 1.0, Vector3.ZERO, Color(0.2, 0.35, 0.7))
			for y in [-0.3, 0.3]:
				Figure.cyl(body, 0.42, 0.06, Vector3(0, y, 0), Color(0.3, 0.3, 0.32))
			_cyl_shape(body, 0.4, 1.0)
		3:
			var colors := [Color.RED, Color.WHITE, Color(0.1, 0.4, 1.0), Color.YELLOW]
			Figure.sphere(body, 0.45, Vector3.ZERO, Color.WHITE)
			for i in 4:
				var band := Figure.cyl(body, 0.452, 0.12, Vector3.ZERO, colors[i])
				band.rotation = Vector3(PI * 0.5, TAU * i / 8.0, 0)
			_sphere_shape(body, 0.45)
		4:
			Figure.sphere(body, 0.25, Vector3.ZERO, Color(0.85, 0.12, 0.12))
			_sphere_shape(body, 0.25)
		5:
			Figure.box(body, Vector3(0.6, 0.06, 0.6), Vector3(0, -0.37, 0), Color(1.0, 0.45, 0.05))
			Figure.cyl(body, 0.04, 0.7, Vector3(0, -0.02, 0), Color(1.0, 0.45, 0.05), 0.24)
			Figure.cyl(body, 0.12, 0.1, Vector3(0, 0.02, 0), Color.WHITE, 0.14)
			_box_shape(body, Vector3(0.6, 0.06, 0.6), Vector3(0, -0.37, 0))
			var cone := CylinderShape3D.new()
			cone.radius = 0.16
			cone.height = 0.7
			_shape(body, cone, Vector3(0, -0.02, 0))
		6:
			var c := Color(0.55, 0.32, 0.15)
			Figure.box(body, Vector3(0.5, 0.08, 0.5), Vector3(0, 0, 0), c)
			Figure.box(body, Vector3(0.5, 0.55, 0.08), Vector3(0, 0.3, 0.21), c)
			for x in [-0.21, 0.21]:
				for z in [-0.21, 0.21]:
					Figure.box(body, Vector3(0.06, 0.45, 0.06), Vector3(x, -0.25, z), c.darkened(0.2))
			_box_shape(body, Vector3(0.5, 0.55, 0.5), Vector3(0, -0.2, 0))
			_box_shape(body, Vector3(0.5, 0.55, 0.08), Vector3(0, 0.3, 0.21))
		7:
			var c := Color(0.6, 0.4, 0.2)
			Figure.box(body, Vector3(1.6, 0.08, 1.0), Vector3(0, 0.36, 0), c)
			for x in [-0.72, 0.72]:
				for z in [-0.42, 0.42]:
					Figure.box(body, Vector3(0.08, 0.72, 0.08), Vector3(x, 0, z), c.darkened(0.2))
			_box_shape(body, Vector3(1.6, 0.08, 1.0), Vector3(0, 0.36, 0))
			_box_shape(body, Vector3(1.5, 0.7, 0.9), Vector3(0, -0.02, 0))
		8:
			var pm := PrismMesh.new()
			pm.left_to_right = 0.0
			pm.size = Vector3(4.0, 1.0, 2.0)
			var mi := MeshInstance3D.new()
			mi.mesh = pm
			mi.material_override = Figure.mat(Color(0.75, 0.75, 0.78))
			mi.rotation.y = PI * 0.5
			body.add_child(mi)
			_shape(body, pm.create_convex_shape(), Vector3.ZERO, Vector3(0, PI * 0.5, 0))
		9:
			var tire := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = 0.22
			tm.outer_radius = 0.45
			tire.mesh = tm
			tire.material_override = Figure.mat(Color(0.1, 0.1, 0.1))
			body.add_child(tire)
			_cyl_shape(body, 0.45, 0.24)
		10:
			var melon := Figure.sphere(body, 0.32, Vector3.ZERO, Color(0.2, 0.55, 0.15))
			melon.scale = Vector3(1, 0.85, 1.25)
			for i in 3:
				var stripe := Figure.cyl(body, 0.322, 0.05, Vector3.ZERO, Color(0.1, 0.35, 0.08))
				stripe.rotation = Vector3(PI * 0.5, TAU * i / 6.0, 0)
				stripe.scale = Vector3(1, 1, 1)
			_sphere_shape(body, 0.32)
		11:
			Figure.cyl(body, 0.09, 0.25, Vector3(0, 0.22, 0), Color.WHITE, 0.07)
			Figure.sphere(body, 0.09, Vector3(0, 0.36, 0), Color.WHITE)
			Figure.cyl(body, 0.1, 0.06, Vector3(0, 0.12, 0), Color(0.85, 0.1, 0.1))
			Figure.cyl(body, 0.07, 0.38, Vector3(0, -0.1, 0), Color.WHITE, 0.16)
			var cap := CapsuleShape3D.new()
			cap.radius = 0.15
			cap.height = 0.9
			_shape(body, cap)
		12:
			Figure.sphere(body, 0.35, Vector3.ZERO, Color.WHITE)
			for d in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0)]:
				var patch := Figure.cyl(body, 0.12, 0.02, d * 0.34, Color(0.08, 0.08, 0.08))
				if absf(d.y) < 0.5:
					patch.rotation = Vector3(PI * 0.5, atan2(d.x, d.z), 0)
			_sphere_shape(body, 0.35)
		13: _car(body, t)
		14: _truck(body, t)
		15: _kart(body, t)
		16: _monster(body, t)
		17: _heli(body, t)
		18: _plane(body, t)
		19:
			var red := Color(0.85, 0.1, 0.08)
			Figure.box(body, Vector3(0.7, 0.6, 0.6), Vector3.ZERO, red)
			Figure.box(body, Vector3(0.72, 0.15, 0.62), Vector3.ZERO, Color(0.95, 0.9, 0.8))
			for z in [-0.311, 0.311]:
				var l := Label3D.new()
				l.text = "TNT"
				l.font_size = 64
				l.pixel_size = 0.004
				l.outline_size = 0
				l.modulate = Color.BLACK
				l.position = Vector3(0, 0, z)
				l.rotation.y = 0.0 if z > 0 else PI
				body.add_child(l)
			Figure.cyl(body, 0.015, 0.2, Vector3(0, 0.4, 0), Color(0.3, 0.3, 0.3))
			_box_shape(body, Vector3(0.7, 0.6, 0.6))
		20:
			Figure.cyl(body, 0.4, 1.0, Vector3.ZERO, Color(0.85, 0.12, 0.1))
			for y in [-0.3, 0.3]:
				Figure.cyl(body, 0.42, 0.08, Vector3(0, y, 0), Color(1.0, 0.8, 0.1))
			_cyl_shape(body, 0.4, 1.0)
		21:
			var hull := Color(0.95, 0.95, 0.97)
			Figure.box(body, Vector3(2.0, 0.5, 3.6), Vector3(0, 0.25, 0.3), hull)
			Figure.box(body, Vector3(2.02, 0.12, 3.62), Vector3(0, 0.1, 0.3), Color(0.15, 0.35, 0.75))
			var bow := MeshInstance3D.new()
			var pm := PrismMesh.new()
			pm.size = Vector3(2.0, 1.2, 0.5)
			bow.mesh = pm
			bow.material_override = Figure.mat(hull)
			bow.rotation = Vector3(PI * 0.5, 0, 0)
			bow.position = Vector3(0, 0.25, -2.05)
			body.add_child(bow)
			Figure.box(body, Vector3(1.6, 0.1, 1.0), Vector3(0, 0.55, 1.2), Color(0.55, 0.38, 0.2))
			Figure.box(body, Vector3(0.4, 0.6, 0.4), Vector3(0, 0.55, 2.2), Color(0.2, 0.2, 0.22))
			_glass(body, Vector3(1.6, 0.45, 0.05), Vector3(0, 0.75, -0.3), -0.3)
			_box_shape(body, Vector3(2.0, 0.5, 4.4), Vector3(0, 0.25, 0.0))
	match type:
		BUTTON:
			Figure.box(body, Vector3(0.12, 1.0, 0.12), Vector3(0, -0.1, 0), Color(0.4, 0.4, 0.42))
			Figure.box(body, Vector3(0.5, 0.3, 0.3), Vector3(0, 0.45, 0), Color(0.3, 0.3, 0.32))
			var cap := Node3D.new()
			cap.name = "Cap"
			cap.position = Vector3(0, 0.45, -0.17)
			body.add_child(cap)
			Figure.cyl(cap, 0.1, 0.08, Vector3.ZERO, Color(0.9, 0.1, 0.1)).rotation.x = PI * 0.5
			Figure.box(body, Vector3(0.5, 0.1, 0.5), Vector3(0, -0.6, 0), Color(0.3, 0.3, 0.32))
			_box_shape(body, Vector3(0.5, 1.25, 0.5), Vector3(0, -0.02, 0))
		PLATE:
			Figure.box(body, Vector3(1.6, 0.08, 1.6), Vector3.ZERO, Color(0.45, 0.45, 0.48))
			var top := Node3D.new()
			top.name = "Cap"
			body.add_child(top)
			Figure.box(top, Vector3(1.3, 0.06, 1.3), Vector3(0, 0.06, 0), Color(0.95, 0.8, 0.1))
			_box_shape(body, Vector3(1.6, 0.1, 1.6))
		LAMP:
			Figure.box(body, Vector3(0.5, 0.08, 0.5), Vector3(0, -1.1, 0), Color(0.2, 0.2, 0.22))
			Figure.cyl(body, 0.05, 2.1, Vector3(0, -0.05, 0), Color(0.2, 0.2, 0.22))
			Figure.cyl(body, 0.12, 0.25, Vector3(0, 1.05, 0), Color(0.2, 0.2, 0.22), 0.3)
			var bulb := Figure.sphere(body, 0.14, Vector3(0, 0.92, 0), Color(1.0, 0.95, 0.7))
			bulb.name = "Bulb"
			bulb.material_override = Figure.glow_mat(Color(1.0, 0.95, 0.7))
			var light := OmniLight3D.new()
			light.name = "Light"
			light.position = Vector3(0, 0.8, 0)
			light.light_color = Color(1.0, 0.9, 0.7)
			light.light_energy = 2.0
			light.omni_range = 14.0
			light.shadow_enabled = true
			body.add_child(light)
			_box_shape(body, Vector3(0.5, 2.3, 0.5), Vector3(0, -0.05, 0))
	if type == CHECKPOINT:
		for x in [-4.0, 4.0]:
			Figure.box(body, Vector3(0.4, 4.0, 0.4), Vector3(x, 1.7, 0), Color(0.95, 0.95, 0.95))
			_box_shape(body, Vector3(0.4, 4.0, 0.4), Vector3(x, 1.7, 0))
		Figure.box(body, Vector3(8.4, 0.8, 0.2), Vector3(0, 3.9, 0), Color(0.15, 0.7, 0.3))
		for i in 8:
			Figure.box(body, Vector3(0.5, 0.4, 0.22), Vector3(-3.5 + i, 3.9, 0), Color.WHITE if i % 2 == 0 else Color(0.1, 0.1, 0.1))
		_box_shape(body, Vector3(8.4, 0.8, 0.2), Vector3(0, 3.9, 0))
	if is_vehicle(type) and t.has("wheels"):
		_wheels(body, t)


static func _wheels(body: Node3D, t: Dictionary) -> void:
	var r: float = t["wheel_r"]
	var wheels: Array = t["wheels"]
	for i in wheels.size():
		var w := Node3D.new()
		w.name = "Wheel%d" % i
		var mount: Vector3 = wheels[i]
		w.position = mount - Vector3(0, t["rest"], 0)
		body.add_child(w)
		var spin := Node3D.new()
		spin.name = "Spin"
		w.add_child(spin)
		if t["kind"] == HELI:
			continue
		var tire := Figure.cyl(spin, r, r * 0.8, Vector3.ZERO, Color(0.08, 0.08, 0.08))
		tire.rotation.z = PI * 0.5
		var hub := Figure.cyl(spin, r * 0.5, r * 0.82, Vector3.ZERO, Color(0.75, 0.75, 0.78))
		hub.rotation.z = PI * 0.5


static func _glass(body: Node3D, size: Vector3, pos: Vector3, rot_x := 0.0) -> void:
	var g := Figure.box(body, size, pos, Color(0.5, 0.7, 0.9, 0.4))
	g.material_override = Figure.glass_mat(Color(0.5, 0.7, 0.9, 0.4))
	g.rotation.x = rot_x


static func _car(body: Node3D, _t: Dictionary) -> void:
	var c := Color(0.85, 0.1, 0.12)
	Figure.box(body, Vector3(1.8, 0.55, 3.9), Vector3(0, 0.55, 0), c)
	Figure.box(body, Vector3(1.6, 0.55, 1.9), Vector3(0, 1.1, 0.3), c.darkened(0.1))
	_glass(body, Vector3(1.5, 0.5, 0.05), Vector3(0, 1.08, -0.68), -0.5)
	_glass(body, Vector3(1.62, 0.36, 1.5), Vector3(0, 1.12, 0.35))
	for x in [-0.6, 0.6]:
		var light := Figure.box(body, Vector3(0.35, 0.15, 0.05), Vector3(x, 0.62, -1.96), Color(1, 1, 0.8))
		light.material_override = Figure.glow_mat(Color(1, 1, 0.8))
		var tail := Figure.box(body, Vector3(0.35, 0.15, 0.05), Vector3(x, 0.62, 1.96), Color(1, 0.1, 0.1))
		tail.material_override = Figure.glow_mat(Color(1, 0.1, 0.1))
	_box_shape(body, Vector3(1.8, 0.55, 3.9), Vector3(0, 0.55, 0))
	_box_shape(body, Vector3(1.6, 0.55, 1.9), Vector3(0, 1.1, 0.3))


static func _truck(body: Node3D, _t: Dictionary) -> void:
	var c := Color(0.2, 0.45, 0.8)
	Figure.box(body, Vector3(2.2, 1.6, 1.8), Vector3(0, 1.3, -1.6), c)
	_glass(body, Vector3(2.0, 0.7, 0.05), Vector3(0, 1.7, -2.52))
	Figure.box(body, Vector3(2.2, 0.3, 5.4), Vector3(0, 0.55, 0), Color(0.25, 0.25, 0.27))
	Figure.box(body, Vector3(2.2, 0.9, 3.4), Vector3(0, 1.15, 0.95), Color(0.85, 0.85, 0.85))
	_box_shape(body, Vector3(2.2, 1.6, 1.8), Vector3(0, 1.3, -1.6))
	_box_shape(body, Vector3(2.2, 0.3, 5.4), Vector3(0, 0.55, 0))
	_box_shape(body, Vector3(2.2, 0.9, 3.4), Vector3(0, 1.15, 0.95))


static func _kart(body: Node3D, _t: Dictionary) -> void:
	var c := Color(1.0, 0.75, 0.1)
	Figure.box(body, Vector3(1.1, 0.15, 1.9), Vector3(0, 0.2, 0), c)
	Figure.box(body, Vector3(0.6, 0.5, 0.15), Vector3(0, 0.5, 0.55), Color(0.15, 0.15, 0.15))
	Figure.box(body, Vector3(1.2, 0.12, 0.3), Vector3(0, 0.3, -0.95), c.darkened(0.2))
	Figure.cyl(body, 0.15, 0.04, Vector3(0, 0.55, -0.35), Color(0.1, 0.1, 0.1)).rotation.x = 1.0
	_box_shape(body, Vector3(1.1, 0.3, 1.9), Vector3(0, 0.25, 0))


static func _monster(body: Node3D, _t: Dictionary) -> void:
	var c := Color(0.2, 0.7, 0.25)
	Figure.box(body, Vector3(2.0, 0.7, 3.6), Vector3(0, 1.55, 0), c)
	Figure.box(body, Vector3(1.8, 0.7, 1.6), Vector3(0, 2.2, -0.1), c.darkened(0.15))
	_glass(body, Vector3(1.7, 0.6, 0.05), Vector3(0, 2.2, -0.92))
	Figure.box(body, Vector3(2.4, 0.15, 0.3), Vector3(0, 1.3, -1.85), Color(0.3, 0.3, 0.3))
	_box_shape(body, Vector3(2.0, 0.7, 3.6), Vector3(0, 1.55, 0))
	_box_shape(body, Vector3(1.8, 0.7, 1.6), Vector3(0, 2.2, -0.1))


static func _heli(body: Node3D, _t: Dictionary) -> void:
	var c := Color(0.95, 0.85, 0.15)
	Figure.box(body, Vector3(1.8, 1.5, 3.0), Vector3(0, 1.15, -0.2), c)
	_glass(body, Vector3(1.6, 1.0, 0.05), Vector3(0, 1.3, -1.72), -0.3)
	Figure.box(body, Vector3(0.35, 0.35, 3.6), Vector3(0, 1.45, 2.9), c)
	Figure.box(body, Vector3(0.1, 1.0, 0.6), Vector3(0, 1.9, 4.6), c.darkened(0.2))
	for x in [-0.9, 0.9]:
		Figure.box(body, Vector3(0.1, 0.1, 2.8), Vector3(x, 0.2, 0), Color(0.25, 0.25, 0.25))
		for z in [-0.8, 0.8]:
			Figure.box(body, Vector3(0.06, 0.4, 0.06), Vector3(x, 0.4, z), Color(0.25, 0.25, 0.25))
	Figure.cyl(body, 0.08, 0.4, Vector3(0, 2.1, -0.2), Color(0.3, 0.3, 0.3))
	var rotor := Node3D.new()
	rotor.name = "Rotor"
	rotor.position = Vector3(0, 2.32, -0.2)
	body.add_child(rotor)
	for a in [0.0, PI * 0.5]:
		var blade := Figure.box(rotor, Vector3(8.0, 0.05, 0.3), Vector3.ZERO, Color(0.2, 0.2, 0.2))
		blade.rotation.y = a
		blade.set_meta("nomerge", true)
	var tail := Node3D.new()
	tail.name = "TailRotor"
	tail.position = Vector3(0.12, 1.9, 4.6)
	body.add_child(tail)
	Figure.box(tail, Vector3(0.04, 1.2, 0.15), Vector3.ZERO, Color(0.2, 0.2, 0.2))
	_box_shape(body, Vector3(1.8, 1.5, 3.0), Vector3(0, 1.15, -0.2))
	_box_shape(body, Vector3(0.35, 0.35, 3.6), Vector3(0, 1.45, 2.9))
	_box_shape(body, Vector3(2.0, 0.15, 2.8), Vector3(0, 0.2, 0))


static func _plane(body: Node3D, _t: Dictionary) -> void:
	var c := Color(0.95, 0.95, 0.97)
	var stripe := Color(0.85, 0.15, 0.15)
	Figure.box(body, Vector3(1.2, 1.2, 6.0), Vector3(0, 1.2, 0), c)
	Figure.box(body, Vector3(1.22, 0.25, 6.02), Vector3(0, 1.0, 0), stripe)
	_glass(body, Vector3(1.0, 0.5, 1.2), Vector3(0, 1.9, -0.8))
	Figure.box(body, Vector3(10.0, 0.15, 1.7), Vector3(0, 1.1, -0.3), c)
	for x in [-4.8, 4.8]:
		Figure.box(body, Vector3(0.4, 0.17, 1.72), Vector3(x, 1.1, -0.3), stripe)
	Figure.box(body, Vector3(3.4, 0.1, 0.9), Vector3(0, 1.4, 2.7), c)
	Figure.box(body, Vector3(0.1, 1.3, 1.0), Vector3(0, 2.0, 2.7), stripe)
	Figure.cyl(body, 0.25, 0.4, Vector3(0, 1.2, -3.15), Color(0.3, 0.3, 0.3)).rotation.x = PI * 0.5
	var prop := Node3D.new()
	prop.name = "Prop"
	prop.position = Vector3(0, 1.2, -3.4)
	body.add_child(prop)
	Figure.box(prop, Vector3(2.4, 0.18, 0.06), Vector3.ZERO, Color(0.15, 0.15, 0.15))
	for x in [-1.2, 1.2]:
		Figure.box(body, Vector3(0.06, 0.6, 0.06), Vector3(x, 0.6, 0.5), Color(0.3, 0.3, 0.3))
	Figure.box(body, Vector3(0.06, 0.6, 0.06), Vector3(0, 0.6, -2.4), Color(0.3, 0.3, 0.3))
	_box_shape(body, Vector3(1.2, 1.2, 6.0), Vector3(0, 1.2, 0))
	_box_shape(body, Vector3(10.0, 0.15, 1.7), Vector3(0, 1.1, -0.3))
	_box_shape(body, Vector3(3.4, 0.1, 0.9), Vector3(0, 1.4, 2.7))
