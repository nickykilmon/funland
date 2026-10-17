extends RefCounted
# Builds the blocky "funfig" player model out of simple meshes.
# Feet sit at y = 0 and the figure faces -Z (Godot's forward).

const HATS := [
	"None", "Cap", "Top Hat", "Crown", "Short Hair", "Long Hair", "Ponytail", "Beanie", "Cowboy Hat",
	"Wizard Hat", "Party Hat", "Viking Helmet", "Chef Hat", "Propeller Cap", "Headphones", "Halo",
	"Bunny Ears", "Space Helmet", "Pirate Hat",
	"Ninja Headband", "Santa Hat", "Pumpkin Head", "Dino Hood", "Graduation Cap", "Construction Helmet",
	"Pilot Goggles", "Golden Crown", "Flower Crown", "Traffic Cone Hat", "Unicorn Horn", "Astronaut Helmet",
]
const FACES := ["Smile", "Grin", "Wink", "Surprised", "Cool Shades", "Angry", "Sleepy", "Beard", "Freckles", "Robot",
	"Star Eyes", "Heart Eyes", "Tongue Out", "Monocle", "Clown"]
const PRINTS := ["Plain", "Stripes", "Star", "Heart", "Tie", "Suit", "Overalls", "Hoodie", "Lightning",
	"Flames", "Checkers", "Dodgeball Champ", "Rainbow"]
const LEGS := ["Pants", "Shorts", "Skirt", "Boots", "Robot Legs", "Rainbow Socks"]
const ACCESSORIES := ["None", "Backpack", "Cape", "Jetpack", "Wings", "Sword", "Guitar", "Scarf", "Balloon",
	"Angel Wings", "Dragon Wings", "Shield", "Pet Duck", "Rocket Pack"]
const RAINBOW := [Color(0.9, 0.15, 0.15), Color(1.0, 0.55, 0.1), Color(1.0, 0.9, 0.15), Color(0.2, 0.75, 0.25), Color(0.2, 0.45, 0.95), Color(0.6, 0.3, 0.85)]

# Option name -> list of choices, and color name -> default color. Used by the menu and to clean network data.
const OPTIONS := {"hat": HATS, "face": FACES, "print": PRINTS, "legs": LEGS, "acc": ACCESSORIES}
const COLOR_DEFAULTS := {
	"skin": Color(1.0, 0.8, 0.15),
	"shirt": Color(0.85, 0.1, 0.1),
	"pants": Color(0.1, 0.25, 0.75),
	"hat_color": Color(0.35, 0.2, 0.08),
	"print_color": Color(1.0, 1.0, 1.0),
	"acc_color": Color(0.2, 0.45, 0.85),
}

const BLACK := Color(0.05, 0.05, 0.05)
const GOLD := Color(1.0, 0.78, 0.1)

static var _mats := {}
static var _meshes := {}


static func mat(c: Color) -> StandardMaterial3D:
	var key := c.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.3
	_mats[key] = m
	return m


static func glow_mat(c: Color) -> StandardMaterial3D:
	var key := "glow" + c.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 1.5
	_mats[key] = m
	return m


static func glass_mat(c: Color) -> StandardMaterial3D:
	var key := "glass" + c.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.05
	m.metallic_specular = 1.0
	_mats[key] = m
	return m


static func _add(parent: Node, mesh: Mesh, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi


static func box(parent: Node, size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var key := "b%s" % size
	if not _meshes.has(key):
		var bm := BoxMesh.new()
		bm.size = size
		_meshes[key] = bm
	return _add(parent, _meshes[key], pos, c)


# Cylinder (or cone, when r_bottom is given).
static func cyl(parent: Node, r: float, h: float, pos: Vector3, c: Color, r_bottom := -1.0) -> MeshInstance3D:
	if r_bottom < 0.0:
		r_bottom = r
	var key := "c%s_%s_%s" % [r, h, r_bottom]
	if not _meshes.has(key):
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r_bottom
		cm.height = h
		cm.radial_segments = 20
		cm.rings = 1
		_meshes[key] = cm
	return _add(parent, _meshes[key], pos, c)


static func sphere(parent: Node, r: float, pos: Vector3, c: Color) -> MeshInstance3D:
	var key := "s%s" % r
	if not _meshes.has(key):
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		sm.radial_segments = 20
		sm.rings = 10
		_meshes[key] = sm
	return _add(parent, _meshes[key], pos, c)


static func _c(info: Dictionary, key: String) -> Color:
	var v = info.get(key)
	return v if v is Color else COLOR_DEFAULTS[key]


static func _o(info: Dictionary, key: String) -> int:
	var v = info.get(key, 0)
	return clampi(v, 0, OPTIONS[key].size() - 1) if v is int else 0


static func build(info: Dictionary) -> Node3D:
	var skin := _c(info, "skin")
	var shirt := _c(info, "shirt")
	var pants := _c(info, "pants")
	var hc := _c(info, "hat_color")
	var pc := _c(info, "print_color")
	var ac := _c(info, "acc_color")

	var root := Node3D.new()
	root.name = "Figure"
	_legs(root, _o(info, "legs"), pants, skin)
	box(root, Vector3(0.6, 0.12, 0.34), Vector3(0, 0.76, 0), pants)
	box(root, Vector3(0.62, 0.6, 0.34), Vector3(0, 1.12, 0), shirt)
	_print(root, _o(info, "print"), pc, shirt, pants)

	for side in [-1, 1]:
		var arm := Node3D.new()
		arm.name = "ArmL" if side < 0 else "ArmR"
		arm.position = Vector3(0.39 * side, 1.36, 0)
		root.add_child(arm)
		box(arm, Vector3(0.17, 0.5, 0.22), Vector3(0, -0.22, 0), shirt)
		cyl(arm, 0.07, 0.12, Vector3(0, -0.52, -0.02), skin)

	cyl(root, 0.09, 0.06, Vector3(0, 1.45, 0), skin)
	cyl(root, 0.19, 0.34, Vector3(0, 1.65, 0), skin)
	cyl(root, 0.1, 0.07, Vector3(0, 1.855, 0), skin)
	_face(root, _o(info, "face"), hc)
	_hat(root, _o(info, "hat"), hc)
	_accessory(root, _o(info, "acc"), ac)
	return root


static func _legs(root: Node3D, style: int, pants: Color, skin: Color) -> void:
	var leg_color := skin if style == 2 else pants
	for side in [-1, 1]:
		var leg := Node3D.new()
		leg.name = "LegL" if side < 0 else "LegR"
		leg.position = Vector3(0.15 * side, 0.72, 0)
		root.add_child(leg)
		match style:
			1: # shorts
				box(leg, Vector3(0.28, 0.3, 0.34), Vector3(0, -0.2, 0), pants)
				box(leg, Vector3(0.22, 0.34, 0.26), Vector3(0, -0.48, 0), skin)
				box(leg, Vector3(0.28, 0.12, 0.42), Vector3(0, -0.66, -0.04), Color.WHITE)
			4: # robot legs
				var steel := Color(0.6, 0.62, 0.66)
				box(leg, Vector3(0.22, 0.28, 0.26), Vector3(0, -0.18, 0), steel)
				cyl(leg, 0.1, 0.3, Vector3(0, -0.36, 0), Color(0.3, 0.3, 0.33)).rotation.z = PI * 0.5
				box(leg, Vector3(0.22, 0.26, 0.26), Vector3(0, -0.5, 0), steel)
				box(leg, Vector3(0.3, 0.12, 0.44), Vector3(0, -0.66, -0.04), Color(0.3, 0.3, 0.33))
			5: # rainbow socks
				box(leg, Vector3(0.28, 0.3, 0.34), Vector3(0, -0.2, 0), pants)
				for i in 4:
					box(leg, Vector3(0.26, 0.08, 0.3), Vector3(0, -0.39 - i * 0.07, 0), RAINBOW[i])
				box(leg, Vector3(0.28, 0.12, 0.42), Vector3(0, -0.66, -0.04), Color.WHITE)
			3: # boots
				var brown := Color(0.3, 0.17, 0.07)
				box(leg, Vector3(0.28, 0.4, 0.34), Vector3(0, -0.24, 0), pants)
				box(leg, Vector3(0.3, 0.3, 0.36), Vector3(0, -0.5, 0), brown)
				box(leg, Vector3(0.3, 0.12, 0.44), Vector3(0, -0.66, -0.04), brown)
			_:
				box(leg, Vector3(0.28, 0.62, 0.34), Vector3(0, -0.36, 0), leg_color)
				box(leg, Vector3(0.28, 0.12, 0.42), Vector3(0, -0.66, -0.04), BLACK if style == 2 else pants)
	if style == 2:
		cyl(root, 0.31, 0.36, Vector3(0, 0.6, 0), pants, 0.42)


static func _print(root: Node3D, style: int, pc: Color, shirt: Color, pants: Color) -> void:
	var z := -0.172
	match style:
		1: # stripes
			for y in [0.92, 1.08, 1.24]:
				box(root, Vector3(0.63, 0.07, 0.35), Vector3(0, y, 0), pc)
		2: # star
			for a in [0.0, PI / 3.0, -PI / 3.0]:
				box(root, Vector3(0.24, 0.06, 0.01), Vector3(0, 1.14, z), pc).rotation.z = a
		3: # heart
			box(root, Vector3(0.13, 0.13, 0.01), Vector3(0, 1.1, z), pc).rotation.z = PI / 4.0
			for x in [-0.046, 0.046]:
				cyl(root, 0.066, 0.01, Vector3(x, 1.15, z), pc).rotation.x = PI / 2.0
		4: # tie
			box(root, Vector3(0.09, 0.06, 0.01), Vector3(0, 1.38, z), pc)
			box(root, Vector3(0.07, 0.3, 0.01), Vector3(0, 1.2, z), pc)
			box(root, Vector3(0.07, 0.07, 0.01), Vector3(0, 1.05, z), pc).rotation.z = PI / 4.0
		5: # suit
			for side in [-1, 1]:
				box(root, Vector3(0.07, 0.36, 0.01), Vector3(0.09 * side, 1.24, z), pc).rotation.z = 0.35 * side
			for y in [1.0, 0.9]:
				box(root, Vector3(0.04, 0.04, 0.012), Vector3(0, y, z), pc)
		6: # overalls
			box(root, Vector3(0.42, 0.34, 0.01), Vector3(0, 0.99, z), pants)
			for side in [-1, 1]:
				box(root, Vector3(0.07, 0.24, 0.352), Vector3(0.16 * side, 1.3, 0), pants)
				box(root, Vector3(0.04, 0.04, 0.012), Vector3(0.16 * side, 1.15, z - 0.002), pc)
		7: # hoodie
			box(root, Vector3(0.36, 0.14, 0.01), Vector3(0, 0.92, z), pc)
			box(root, Vector3(0.5, 0.16, 0.12), Vector3(0, 1.44, 0.14), shirt.darkened(0.15))
			for x in [-0.06, 0.06]:
				box(root, Vector3(0.02, 0.14, 0.01), Vector3(x, 1.32, z), pc)
		9: # flames
			for i in 5:
				var f := box(root, Vector3(0.09, 0.3 + (i % 2) * 0.12, 0.01), Vector3(-0.22 + i * 0.11, 0.98, z), Color(1.0, 0.45, 0.05))
				f.rotation.z = 0.2 - (i % 2) * 0.4
				box(root, Vector3(0.05, 0.16, 0.012), Vector3(-0.22 + i * 0.11, 0.93, z - 0.002), Color(1.0, 0.85, 0.1))
		10: # checkers
			for cx in 4:
				for cy in 3:
					if (cx + cy) % 2 == 0:
						box(root, Vector3(0.14, 0.14, 0.01), Vector3(-0.21 + cx * 0.14, 0.94 + cy * 0.15, z), pc)
		11: # dodgeball champ
			cyl(root, 0.15, 0.01, Vector3(0, 1.14, z), Color(0.85, 0.12, 0.12)).rotation.x = PI * 0.5
			box(root, Vector3(0.05, 0.16, 0.012), Vector3(0, 1.14, z - 0.003), GOLD)
		12: # rainbow
			for i in 6:
				box(root, Vector3(0.63, 0.09, 0.35), Vector3(0, 0.88 + i * 0.09, 0), RAINBOW[i])
		8: # lightning
			box(root, Vector3(0.05, 0.2, 0.01), Vector3(0.02, 1.25, z), pc).rotation.z = -0.5
			box(root, Vector3(0.14, 0.05, 0.01), Vector3(0.0, 1.15, z), pc)
			box(root, Vector3(0.05, 0.2, 0.01), Vector3(-0.01, 1.05, z), pc).rotation.z = -0.5


static func _face(root: Node3D, face: int, hc: Color) -> void:
	var z := -0.185
	var eyes := true
	var smile := true
	match face:
		1: # grin
			smile = false
			box(root, Vector3(0.18, 0.06, 0.02), Vector3(0, 1.58, z), BLACK)
			box(root, Vector3(0.15, 0.025, 0.02), Vector3(0, 1.59, z - 0.003), Color.WHITE)
		2: # wink
			eyes = false
			box(root, Vector3(0.05, 0.07, 0.02), Vector3(-0.07, 1.69, z), BLACK)
			box(root, Vector3(0.07, 0.02, 0.02), Vector3(0.07, 1.68, z), BLACK)
		3: # surprised
			eyes = false
			smile = false
			for x in [-0.07, 0.07]:
				box(root, Vector3(0.05, 0.09, 0.02), Vector3(x, 1.7, z), BLACK)
			box(root, Vector3(0.06, 0.07, 0.02), Vector3(0, 1.57, z), BLACK)
		4: # cool shades
			eyes = false
			box(root, Vector3(0.34, 0.08, 0.02), Vector3(0, 1.69, z - 0.01), BLACK)
		5: # angry
			smile = false
			box(root, Vector3(0.08, 0.022, 0.02), Vector3(-0.07, 1.75, z), BLACK).rotation.z = -0.4
			box(root, Vector3(0.08, 0.022, 0.02), Vector3(0.07, 1.75, z), BLACK).rotation.z = 0.4
			box(root, Vector3(0.12, 0.025, 0.02), Vector3(0, 1.58, z), BLACK)
			for x in [-0.07, 0.07]:
				box(root, Vector3(0.025, 0.025, 0.02), Vector3(x, 1.565, z), BLACK)
		6: # sleepy
			eyes = false
			smile = false
			for x in [-0.07, 0.07]:
				box(root, Vector3(0.07, 0.02, 0.02), Vector3(x, 1.68, z), BLACK)
			box(root, Vector3(0.05, 0.03, 0.02), Vector3(0, 1.58, z), BLACK)
		7: # beard
			box(root, Vector3(0.34, 0.14, 0.08), Vector3(0, 1.53, -0.15), hc)
			box(root, Vector3(0.16, 0.03, 0.03), Vector3(0, 1.615, z - 0.005), hc)
			smile = false
		8: # freckles
			for x in [-0.12, -0.105, -0.13, 0.12, 0.105, 0.13]:
				box(root, Vector3(0.015, 0.015, 0.02), Vector3(x, 1.63 + fposmod(x * 100.0, 3.0) * 0.008, z + 0.012), Color(0.7, 0.35, 0.1))
		10: # star eyes
			eyes = false
			for x in [-0.07, 0.07]:
				for a in [0.0, PI / 3.0, -PI / 3.0]:
					box(root, Vector3(0.08, 0.025, 0.02), Vector3(x, 1.69, z), GOLD).rotation.z = a
		11: # heart eyes
			eyes = false
			smile = false
			for x in [-0.075, 0.075]:
				box(root, Vector3(0.05, 0.05, 0.02), Vector3(x, 1.68, z), Color(0.9, 0.1, 0.2)).rotation.z = PI / 4.0
				for dx in [-0.017, 0.017]:
					cyl(root, 0.022, 0.02, Vector3(x + dx, 1.698, z), Color(0.9, 0.1, 0.2)).rotation.x = PI / 2.0
			box(root, Vector3(0.18, 0.06, 0.02), Vector3(0, 1.58, z), BLACK)
		12: # tongue out
			box(root, Vector3(0.06, 0.07, 0.02), Vector3(0.02, 1.545, z - 0.003), Color(1.0, 0.45, 0.55))
		13: # monocle
			var mono := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = 0.04
			tm.outer_radius = 0.052
			mono.mesh = tm
			mono.material_override = mat(GOLD)
			mono.position = Vector3(0.07, 1.69, z - 0.01)
			mono.rotation.x = PI / 2.0
			root.add_child(mono)
			box(root, Vector3(0.16, 0.03, 0.03), Vector3(0, 1.615, z - 0.005), Color(0.35, 0.2, 0.08))
		14: # clown
			smile = false
			sphere(root, 0.045, Vector3(0, 1.63, z - 0.02), Color(0.95, 0.1, 0.1))
			box(root, Vector3(0.2, 0.05, 0.02), Vector3(0, 1.57, z), Color(0.9, 0.1, 0.1))
			for x in [-0.1, 0.1]:
				box(root, Vector3(0.04, 0.05, 0.02), Vector3(x, 1.59, z), Color(0.9, 0.1, 0.1))
		9: # robot
			eyes = false
			smile = false
			var visor := box(root, Vector3(0.3, 0.07, 0.02), Vector3(0, 1.69, z), Color(0.2, 0.9, 1.0))
			visor.material_override = glow_mat(Color(0.2, 0.9, 1.0))
			for x in [-0.04, 0.0, 0.04]:
				box(root, Vector3(0.015, 0.07, 0.02), Vector3(x, 1.57, z), Color(0.3, 0.3, 0.32))
	if eyes:
		for x in [-0.07, 0.07]:
			box(root, Vector3(0.05, 0.07, 0.02), Vector3(x, 1.69, z), BLACK)
	if smile:
		box(root, Vector3(0.14, 0.025, 0.02), Vector3(0, 1.58, z), BLACK)
		for x in [-0.075, 0.075]:
			box(root, Vector3(0.025, 0.025, 0.02), Vector3(x, 1.595, z), BLACK)


static func _hat(root: Node3D, hat: int, hc: Color) -> void:
	match hat:
		1: # cap
			cyl(root, 0.21, 0.1, Vector3(0, 1.84, 0), hc)
			box(root, Vector3(0.3, 0.03, 0.2), Vector3(0, 1.81, -0.25), hc)
		2: # top hat
			cyl(root, 0.26, 0.03, Vector3(0, 1.83, 0), BLACK)
			cyl(root, 0.17, 0.32, Vector3(0, 2.0, 0), BLACK)
			cyl(root, 0.175, 0.05, Vector3(0, 1.88, 0), hc)
		3: # crown
			cyl(root, 0.21, 0.1, Vector3(0, 1.86, 0), GOLD)
			for i in 6:
				var a := TAU * i / 6.0
				box(root, Vector3(0.06, 0.1, 0.06), Vector3(cos(a) * 0.18, 1.95, sin(a) * 0.18), GOLD)
			sphere(root, 0.035, Vector3(0, 1.87, -0.21), Color(0.9, 0.1, 0.2))
		4: # short hair
			cyl(root, 0.21, 0.12, Vector3(0, 1.83, 0), hc)
			box(root, Vector3(0.4, 0.24, 0.12), Vector3(0, 1.73, 0.13), hc)
		5: # long hair
			cyl(root, 0.21, 0.12, Vector3(0, 1.83, 0), hc)
			box(root, Vector3(0.42, 0.55, 0.12), Vector3(0, 1.58, 0.14), hc)
			for side in [-1, 1]:
				box(root, Vector3(0.06, 0.36, 0.28), Vector3(0.2 * side, 1.66, 0.02), hc)
		6: # ponytail
			cyl(root, 0.21, 0.12, Vector3(0, 1.83, 0), hc)
			box(root, Vector3(0.4, 0.2, 0.12), Vector3(0, 1.74, 0.13), hc)
			sphere(root, 0.08, Vector3(0, 1.8, 0.24), hc)
			box(root, Vector3(0.1, 0.34, 0.1), Vector3(0, 1.6, 0.28), hc)
		7: # beanie
			cyl(root, 0.205, 0.16, Vector3(0, 1.88, 0), hc, 0.215)
			cyl(root, 0.222, 0.07, Vector3(0, 1.8, 0), hc.lightened(0.25))
			sphere(root, 0.065, Vector3(0, 1.99, 0), hc.lightened(0.4))
		8: # cowboy hat
			cyl(root, 0.4, 0.03, Vector3(0, 1.84, 0), hc)
			cyl(root, 0.17, 0.2, Vector3(0, 1.95, 0), hc, 0.19)
			cyl(root, 0.195, 0.04, Vector3(0, 1.87, 0), BLACK)
		9: # wizard hat
			cyl(root, 0.34, 0.03, Vector3(0, 1.84, 0), hc)
			cyl(root, 0.0, 0.6, Vector3(0, 2.15, 0), hc, 0.21)
			box(root, Vector3(0.06, 0.06, 0.02), Vector3(0, 2.0, -0.16), GOLD).rotation.z = PI / 4.0
		10: # party hat
			cyl(root, 0.0, 0.34, Vector3(0, 2.0, 0), hc, 0.15)
			sphere(root, 0.05, Vector3(0, 2.18, 0), Color.WHITE)
			cyl(root, 0.11, 0.04, Vector3(0, 1.94, 0), Color.WHITE, 0.12)
		11: # viking helmet
			var steel := Color(0.6, 0.6, 0.65)
			cyl(root, 0.17, 0.16, Vector3(0, 1.88, 0), steel, 0.215)
			cyl(root, 0.225, 0.05, Vector3(0, 1.81, 0), hc)
			for side in [-1, 1]:
				cyl(root, 0.0, 0.24, Vector3(0.26 * side, 1.96, 0), Color(0.95, 0.92, 0.8), 0.05).rotation.z = -1.0 * side
		12: # chef hat
			cyl(root, 0.2, 0.22, Vector3(0, 1.95, 0), Color.WHITE)
			sphere(root, 0.25, Vector3(0, 2.12, 0), Color.WHITE)
		13: # propeller cap
			cyl(root, 0.21, 0.1, Vector3(0, 1.84, 0), hc)
			box(root, Vector3(0.3, 0.03, 0.2), Vector3(0, 1.81, -0.25), hc)
			cyl(root, 0.015, 0.1, Vector3(0, 1.94, 0), Color(0.3, 0.3, 0.3))
			var prop := Node3D.new()
			prop.name = "Propeller"
			prop.position = Vector3(0, 1.99, 0)
			root.add_child(prop)
			box(prop, Vector3(0.42, 0.015, 0.07), Vector3.ZERO, Color(1.0, 0.8, 0.1))
			box(prop, Vector3(0.07, 0.016, 0.42), Vector3.ZERO, Color(0.2, 0.7, 1.0))
		14: # headphones
			box(root, Vector3(0.46, 0.04, 0.06), Vector3(0, 1.89, 0), Color(0.15, 0.15, 0.15))
			for side in [-1, 1]:
				box(root, Vector3(0.04, 0.2, 0.06), Vector3(0.23 * side, 1.8, 0), Color(0.15, 0.15, 0.15))
				cyl(root, 0.08, 0.07, Vector3(0.215 * side, 1.68, 0), hc).rotation.z = PI / 2.0
		15: # halo
			var halo := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = 0.14
			tm.outer_radius = 0.19
			halo.mesh = tm
			halo.material_override = glow_mat(Color(1.0, 0.9, 0.4))
			halo.position = Vector3(0, 2.08, 0)
			root.add_child(halo)
		16: # bunny ears
			for side in [-1, 1]:
				var ear := box(root, Vector3(0.08, 0.32, 0.04), Vector3(0.08 * side, 2.02, 0), hc)
				ear.rotation.z = -0.15 * side
				box(ear, Vector3(0.04, 0.24, 0.01), Vector3(0, 0, -0.022), Color(1.0, 0.6, 0.7))
		17: # space helmet
			var glass := sphere(root, 0.3, Vector3(0, 1.67, 0), Color(0.7, 0.9, 1.0, 0.25))
			glass.material_override = glass_mat(Color(0.7, 0.9, 1.0, 0.25))
			cyl(root, 0.25, 0.06, Vector3(0, 1.43, 0), Color.WHITE)
		19: # ninja headband
			cyl(root, 0.197, 0.06, Vector3(0, 1.75, 0), hc)
			for side in [-1, 1]:
				box(root, Vector3(0.04, 0.2, 0.03), Vector3(0.04 * side, 1.66, 0.2), hc).rotation.z = 0.3 * side
		20: # santa hat
			var santa := cyl(root, 0.0, 0.45, Vector3(0, 2.02, 0.04), Color(0.85, 0.1, 0.1), 0.2)
			santa.rotation.x = 0.35
			cyl(root, 0.22, 0.08, Vector3(0, 1.82, 0), Color.WHITE)
			sphere(root, 0.06, Vector3(0, 2.2, 0.14), Color.WHITE)
		21: # pumpkin head
			var pumpkin := sphere(root, 0.3, Vector3(0, 1.68, 0), Color(1.0, 0.5, 0.08))
			pumpkin.scale = Vector3(1.0, 0.85, 1.0)
			cyl(root, 0.04, 0.12, Vector3(0, 1.98, 0), Color(0.25, 0.5, 0.15))
			for x in [-0.1, 0.1]:
				box(root, Vector3(0.07, 0.07, 0.02), Vector3(x, 1.74, -0.29), BLACK).rotation.z = PI / 4.0
			box(root, Vector3(0.2, 0.05, 0.02), Vector3(0, 1.6, -0.285), BLACK)
		22: # dino hood
			var hood := sphere(root, 0.26, Vector3(0, 1.74, 0.03), hc)
			hood.scale = Vector3(1.0, 0.9, 1.0)
			for i in 4:
				cyl(root, 0.0, 0.12, Vector3(0, 1.98 - i * 0.07, 0.04 + i * 0.07), hc.darkened(0.25), 0.05).rotation.x = 0.6 + i * 0.25
			for x in [-0.08, 0.08]:
				box(root, Vector3(0.05, 0.05, 0.02), Vector3(x, 1.93, -0.17), Color.WHITE)
		23: # graduation cap
			cyl(root, 0.2, 0.08, Vector3(0, 1.85, 0), BLACK)
			box(root, Vector3(0.5, 0.03, 0.5), Vector3(0, 1.9, 0), BLACK)
			box(root, Vector3(0.02, 0.2, 0.02), Vector3(0.22, 1.82, -0.22), GOLD)
		24: # construction helmet
			cyl(root, 0.17, 0.15, Vector3(0, 1.89, 0), Color(1.0, 0.82, 0.1), 0.22)
			cyl(root, 0.26, 0.025, Vector3(0, 1.81, -0.02), Color(1.0, 0.82, 0.1))
			box(root, Vector3(0.04, 0.12, 0.3), Vector3(0, 1.92, 0), Color(0.95, 0.75, 0.05))
		25: # pilot goggles
			cyl(root, 0.205, 0.12, Vector3(0, 1.84, 0), Color(0.45, 0.28, 0.12))
			cyl(root, 0.197, 0.04, Vector3(0, 1.79, 0), Color(0.3, 0.2, 0.1))
			for x in [-0.08, 0.08]:
				var g := cyl(root, 0.055, 0.04, Vector3(x, 1.86, -0.18), Color(0.4, 0.8, 1.0))
				g.rotation.x = PI / 2.0 - 0.4
				g.material_override = glass_mat(Color(0.4, 0.8, 1.0, 0.6))
		26: # golden crown
			cyl(root, 0.22, 0.14, Vector3(0, 1.88, 0), GOLD)
			for i in 8:
				var a := TAU * i / 8.0
				cyl(root, 0.0, 0.14, Vector3(cos(a) * 0.19, 2.01, sin(a) * 0.19), GOLD, 0.045)
			var gems := [Color.RED, Color(0.2, 0.5, 1), Color(0.2, 0.9, 0.3), Color(0.8, 0.3, 1)]
			for i in 4:
				var a := TAU * i / 4.0
				var gem := sphere(root, 0.03, Vector3(cos(a) * 0.222, 1.88, sin(a) * 0.222), gems[i])
				gem.material_override = glow_mat(gems[i])
		27: # flower crown
			for i in 10:
				var a := TAU * i / 10.0
				sphere(root, 0.05, Vector3(cos(a) * 0.2, 1.83, sin(a) * 0.2), RAINBOW[i % RAINBOW.size()].lightened(0.3))
			cyl(root, 0.2, 0.025, Vector3(0, 1.82, 0), Color(0.3, 0.6, 0.2))
		28: # traffic cone hat
			cyl(root, 0.0, 0.5, Vector3(0, 2.1, 0), Color(1.0, 0.45, 0.05), 0.2)
			cyl(root, 0.11, 0.07, Vector3(0, 2.05, 0), Color.WHITE, 0.13)
			box(root, Vector3(0.48, 0.04, 0.48), Vector3(0, 1.85, 0), Color(1.0, 0.45, 0.05))
		29: # unicorn horn
			var horn := cyl(root, 0.0, 0.32, Vector3(0, 2.0, -0.08), Color(1.0, 0.9, 0.5), 0.05)
			horn.rotation.x = -0.35
			for i in 4:
				box(root, Vector3(0.05, 0.08 + i * 0.04, 0.1), Vector3(0, 1.84 - i * 0.05, 0.14 + i * 0.02), RAINBOW[i])
		30: # astronaut helmet
			sphere(root, 0.3, Vector3(0, 1.67, 0), Color.WHITE)
			var visor := box(root, Vector3(0.36, 0.22, 0.05), Vector3(0, 1.69, -0.26), GOLD)
			visor.material_override = glass_mat(Color(1.0, 0.8, 0.3, 0.85))
			cyl(root, 0.25, 0.06, Vector3(0, 1.43, 0), Color(0.85, 0.85, 0.88))
		18: # pirate hat
			cyl(root, 0.2, 0.08, Vector3(0, 1.85, 0), BLACK)
			var top := box(root, Vector3(0.56, 0.16, 0.2), Vector3(0, 1.94, 0), BLACK)
			top.rotation.x = 0.1
			box(root, Vector3(0.07, 0.07, 0.01), Vector3(0, 1.94, -0.112), Color.WHITE)
			box(root, Vector3(0.57, 0.03, 0.21), Vector3(0, 2.0, 0), hc)


static func _accessory(root: Node3D, acc: int, ac: Color) -> void:
	match acc:
		1: # backpack
			box(root, Vector3(0.46, 0.5, 0.18), Vector3(0, 1.12, 0.27), ac)
			box(root, Vector3(0.48, 0.16, 0.2), Vector3(0, 1.32, 0.27), ac.darkened(0.2))
		2: # cape
			var cape := Node3D.new()
			cape.name = "Cape"
			cape.position = Vector3(0, 1.42, 0.19)
			root.add_child(cape)
			box(cape, Vector3(0.62, 1.05, 0.03), Vector3(0, -0.52, 0), ac)
		3: # jetpack
			box(root, Vector3(0.4, 0.4, 0.12), Vector3(0, 1.14, 0.23), Color(0.55, 0.55, 0.6))
			for side in [-1, 1]:
				cyl(root, 0.09, 0.46, Vector3(0.13 * side, 1.12, 0.33), ac)
				cyl(root, 0.06, 0.08, Vector3(0.13 * side, 0.85, 0.33), Color(0.3, 0.3, 0.3), 0.08)
				var flame := cyl(root, 0.06, 0.16, Vector3(0.13 * side, 0.73, 0.33), Color(1.0, 0.5, 0.1), 0.0)
				flame.material_override = glow_mat(Color(1.0, 0.5, 0.1))
		4: # wings
			for side in [-1, 1]:
				var wing := box(root, Vector3(0.62, 0.34, 0.03), Vector3(0.36 * side, 1.25, 0.22), ac)
				wing.rotation = Vector3(0, -0.4 * side, 0.35 * side)
		5: # sword on back
			var sword := Node3D.new()
			sword.position = Vector3(0, 1.12, 0.21)
			sword.rotation.z = 0.7
			root.add_child(sword)
			box(sword, Vector3(0.07, 0.8, 0.02), Vector3(0, 0.1, 0), Color(0.8, 0.82, 0.88))
			box(sword, Vector3(0.24, 0.05, 0.05), Vector3(0, -0.32, 0), ac)
			box(sword, Vector3(0.06, 0.18, 0.05), Vector3(0, -0.44, 0), Color(0.35, 0.2, 0.08))
		6: # guitar on back
			var guitar := Node3D.new()
			guitar.position = Vector3(0, 1.08, 0.24)
			guitar.rotation.z = -0.55
			root.add_child(guitar)
			box(guitar, Vector3(0.38, 0.42, 0.1), Vector3(0, -0.15, 0), ac)
			box(guitar, Vector3(0.07, 0.6, 0.04), Vector3(0, 0.35, 0), Color(0.4, 0.25, 0.1))
			cyl(guitar, 0.07, 0.01, Vector3(0, -0.1, 0.051), BLACK).rotation.x = PI / 2.0
		7: # scarf
			box(root, Vector3(0.48, 0.1, 0.4), Vector3(0, 1.43, 0), ac)
			box(root, Vector3(0.12, 0.32, 0.04), Vector3(0.13, 1.26, -0.2), ac)
		9: # angel wings
			for side in [-1, 1]:
				for i in 3:
					var w := box(root, Vector3(0.75 - i * 0.18, 0.12, 0.03), Vector3((0.4 + i * 0.03) * side, 1.42 - i * 0.12, 0.22), Color.WHITE)
					w.rotation = Vector3(0, -0.4 * side, (0.5 - i * 0.15) * side)
		10: # dragon wings
			for side in [-1, 1]:
				var wing := Node3D.new()
				wing.position = Vector3(0.2 * side, 1.3, 0.22)
				wing.rotation = Vector3(0, -0.5 * side, 0.3 * side)
				root.add_child(wing)
				box(wing, Vector3(0.8, 0.05, 0.05), Vector3(0.4 * side, 0.2, 0), ac.darkened(0.3))
				for i in 3:
					box(wing, Vector3(0.25, 0.4, 0.02), Vector3((0.2 + i * 0.22) * side, -0.02, 0), ac).rotation.z = 0.2 * side
		11: # shield
			var shield := cyl(root, 0.28, 0.06, Vector3(0, 1.12, 0.23), ac)
			shield.rotation.x = PI / 2.0
			var boss := cyl(root, 0.09, 0.08, Vector3(0, 1.12, 0.26), GOLD)
			boss.rotation.x = PI / 2.0
		12: # pet duck floating next to you
			var pet := Node3D.new()
			pet.name = "Pet"
			pet.position = Vector3(0.7, 1.7, 0.2)
			root.add_child(pet)
			sphere(pet, 0.16, Vector3.ZERO, Color(1.0, 0.9, 0.15))
			sphere(pet, 0.1, Vector3(0, 0.17, -0.1), Color(1.0, 0.9, 0.15))
			box(pet, Vector3(0.08, 0.03, 0.08), Vector3(0, 0.16, -0.22), Color(1.0, 0.5, 0.05))
			for x in [-0.04, 0.04]:
				box(pet, Vector3(0.02, 0.02, 0.01), Vector3(x, 0.2, -0.19), BLACK)
		13: # rocket pack
			for side in [-1, 1]:
				cyl(root, 0.12, 0.6, Vector3(0.14 * side, 1.12, 0.3), Color(0.85, 0.15, 0.12))
				cyl(root, 0.0, 0.18, Vector3(0.14 * side, 1.5, 0.3), Color(0.9, 0.9, 0.92), 0.12)
				box(root, Vector3(0.02, 0.2, 0.16), Vector3(0.24 * side, 0.9, 0.3), Color(0.9, 0.9, 0.92))
				var flame := cyl(root, 0.08, 0.3, Vector3(0.14 * side, 0.68, 0.3), Color(1.0, 0.6, 0.1), 0.0)
				flame.material_override = glow_mat(Color(1.0, 0.6, 0.1))
		8: # balloon held in the left hand
			var arm := root.get_node("ArmL")
			cyl(arm, 0.006, 1.0, Vector3(0, -0.05, -0.02), Color.WHITE)
			sphere(arm, 0.22, Vector3(0, 0.62, -0.02), ac)


# Puts every mesh in the figure on the given render layers (used to hide your own body from your camera).
static func set_layers(node: Node, layers: int) -> void:
	if node is MeshInstance3D:
		node.layers = layers
	for c in node.get_children():
		set_layers(c, layers)
