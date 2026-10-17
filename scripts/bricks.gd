extends RefCounted
# Funbrick shapes, colors and mesh building.
# A brick's size is Vector3i(width studs, height in plates, depth studs), before rotation.
# rot (0-3) turns it in 90 degree steps; odd rotations swap width and depth on the grid.

const STUD := 0.4    # width of one stud
const PLATE := 0.16  # height of one plate (a brick is 3 plates)
const H := 0.48

enum { BRICK, PLATE_SHAPE, TILE, SLOPE, ROUND, WINDOW, DOOR }

const SHAPES := [
	{"name": "Brick", "h": 3, "sizes": [Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3), Vector2i(1, 4), Vector2i(1, 6), Vector2i(2, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 6)]},
	{"name": "Plate", "h": 1, "sizes": [Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 4), Vector2i(2, 2), Vector2i(2, 4), Vector2i(2, 6), Vector2i(4, 4), Vector2i(6, 6), Vector2i(8, 8)]},
	{"name": "Tile", "h": 1, "sizes": [Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 4), Vector2i(2, 2), Vector2i(2, 4), Vector2i(4, 4)]},
	{"name": "Slope", "h": 3, "sizes": [Vector2i(1, 2), Vector2i(2, 2), Vector2i(4, 2), Vector2i(1, 3), Vector2i(2, 3), Vector2i(4, 3)]},
	{"name": "Round", "h": 3, "sizes": [Vector2i(1, 1), Vector2i(2, 2), Vector2i(4, 4)]},
	{"name": "Window", "h": 9, "sizes": [Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1)]},
	{"name": "Door", "h": 15, "sizes": [Vector2i(4, 1)]},
]

const COLORS := [
	Color(0.85, 0.1, 0.1), Color(1.0, 0.5, 0.05), Color(1.0, 0.82, 0.1), Color(0.2, 0.65, 0.2),
	Color(0.1, 0.35, 0.8), Color(0.35, 0.75, 0.95), Color(0.55, 0.25, 0.7), Color(1.0, 0.5, 0.7),
	Color(0.95, 0.95, 0.95), Color(0.6, 0.6, 0.62), Color(0.12, 0.12, 0.13), Color(0.45, 0.28, 0.12),
	Color(0.55, 0.05, 0.1), Color(0.95, 0.8, 0.55), Color(0.6, 0.85, 0.2), Color(0.05, 0.4, 0.3),
	Color(0.1, 0.15, 0.4), Color(0.2, 0.85, 0.75), Color(0.8, 0.6, 1.0), Color(1.0, 0.75, 0.6),
	Color(0.35, 0.35, 0.37), Color(0.75, 0.55, 0.3), Color(1.0, 0.95, 0.6), Color(0.3, 0.15, 0.05),
]

static var _mats := {}
static var _meshes := {}


static func size_for(shape: int, idx: int) -> Vector3i:
	var s: Vector2i = SHAPES[shape]["sizes"][idx]
	return Vector3i(s.x, SHAPES[shape]["h"], s.y)


static func is_valid(shape: int, size: Vector3i, rot: int) -> bool:
	if shape < 0 or shape >= SHAPES.size() or rot < 0 or rot > 3:
		return false
	return size.y == SHAPES[shape]["h"] and SHAPES[shape]["sizes"].has(Vector2i(size.x, size.z))


# World-space extents of a brick (width, height, depth) after rotation.
static func extents(size: Vector3i, rot: int) -> Vector3:
	var w := size.x * STUD
	var d := size.z * STUD
	if rot % 2 == 1:
		var t := w
		w = d
		d = t
	return Vector3(w, size.y * PLATE, d)


# Space a brick takes up (shrunk a hair so bricks touching side by side don't count as overlapping).
static func box_of(pos: Vector3, size: Vector3i, rot: int) -> AABB:
	var half := extents(size, rot) * 0.5 - Vector3(0.01, 0.01, 0.01)
	return AABB(pos - half, half * 2.0)


static func _mat(c: Color, ghost: bool) -> StandardMaterial3D:
	var key := c.to_html() + ("g" if ghost else "")
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.25
	if ghost:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = 0.45
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mats[key] = m
	return m


static func _glass_mat(ghost: bool) -> StandardMaterial3D:
	var key := "glass" + ("g" if ghost else "")
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.6, 0.85, 1.0, 0.18 if ghost else 0.35)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.05
		m.metallic_specular = 1.0
		_mats[key] = m
	return _mats[key]


static func _mesh(key: String, maker: Callable) -> Mesh:
	if not _meshes.has(key):
		_meshes[key] = maker.call()
	return _meshes[key]


static func _box_mesh(size: Vector3) -> Mesh:
	return _mesh("b%s" % size, func():
		var bm := BoxMesh.new()
		bm.size = size
		return bm)


static func _stud_mesh() -> Mesh:
	return _mesh("stud", func():
		var cm := CylinderMesh.new()
		cm.top_radius = 0.12
		cm.bottom_radius = 0.12
		cm.height = 0.1
		cm.radial_segments = 16
		cm.rings = 1
		return cm)


static func _part(root: Node3D, mesh: Mesh, pos: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	root.add_child(mi)
	return mi


static func _collider(body: Node3D, shape: Shape3D, pos := Vector3.ZERO, rot := Vector3.ZERO) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = pos
	cs.rotation = rot
	body.add_child(cs)


static func _box_collider(body: Node3D, size: Vector3, pos := Vector3.ZERO) -> void:
	var bs := BoxShape3D.new()
	bs.size = size
	_collider(body, bs, pos)


static func _studs(root: Node3D, nx: int, nz: int, w: float, d: float, top: float, m: Material, z_from := 0) -> void:
	for ix in nx:
		for iz in range(z_from, nz):
			_part(root, _stud_mesh(), Vector3((ix + 0.5) * STUD - w * 0.5, top + 0.05, (iz + 0.5) * STUD - d * 0.5), m)


# Returns a StaticBody3D brick (or a see-through Node3D ghost) centered on its middle, not yet rotated.
static func make(shape: int, size: Vector3i, c: Color, ghost := false, open := false) -> Node3D:
	var w := size.x * STUD
	var h := size.y * PLATE
	var d := size.z * STUD
	var root: Node3D = Node3D.new() if ghost else StaticBody3D.new()
	var m := _mat(c, ghost)
	match shape:
		SLOPE:
			# full-height row of studs at the back (+z), wedge sloping down to the front (-z)
			_part(root, _box_mesh(Vector3(w - 0.006, h - 0.004, STUD)), Vector3(0, 0, d * 0.5 - STUD * 0.5), m)
			var wedge_len := d - STUD
			var pm := _mesh("wedge%s_%s_%s" % [w, h, wedge_len], func():
				var p := PrismMesh.new()
				p.left_to_right = 0.0
				p.size = Vector3(wedge_len, h - 0.004, w - 0.006)
				return p) as PrismMesh
			var wedge := _part(root, pm, Vector3(0, 0, -STUD * 0.5), m)
			wedge.rotation.y = PI * 0.5
			_studs(root, size.x, size.z, w, d, h * 0.5, m, size.z - 1)
			if not ghost:
				_box_collider(root, Vector3(w, h, STUD), Vector3(0, 0, d * 0.5 - STUD * 0.5))
				_collider(root, pm.create_convex_shape(), Vector3(0, 0, -STUD * 0.5), Vector3(0, PI * 0.5, 0))
		ROUND:
			var r := w * 0.5 - 0.01
			var cm := _mesh("round%s_%s" % [r, h], func():
				var cy := CylinderMesh.new()
				cy.top_radius = r
				cy.bottom_radius = r
				cy.height = h - 0.004
				cy.radial_segments = 24
				cy.rings = 1
				return cy)
			_part(root, cm, Vector3.ZERO, m)
			if size.x == 1:
				_part(root, _stud_mesh(), Vector3(0, h * 0.5 + 0.05, 0), m)
			else:
				_studs(root, size.x, size.z, w, d, h * 0.5, m)
			if not ghost:
				var cs := CylinderShape3D.new()
				cs.radius = w * 0.5
				cs.height = h
				_collider(root, cs)
		WINDOW:
			var t := 0.08
			_part(root, _box_mesh(Vector3(t, h, d)), Vector3(-w * 0.5 + t * 0.5, 0, 0), m)
			_part(root, _box_mesh(Vector3(t, h, d)), Vector3(w * 0.5 - t * 0.5, 0, 0), m)
			_part(root, _box_mesh(Vector3(w, t, d)), Vector3(0, h * 0.5 - t * 0.5, 0), m)
			_part(root, _box_mesh(Vector3(w, t, d)), Vector3(0, -h * 0.5 + t * 0.5, 0), m)
			_part(root, _box_mesh(Vector3(0.04, h - 2 * t, 0.04)), Vector3.ZERO, m)
			_part(root, _box_mesh(Vector3(w - 2 * t, h - 2 * t, 0.03)), Vector3.ZERO, _glass_mat(ghost))
			_studs(root, size.x, size.z, w, d, h * 0.5, m)
			if not ghost:
				_box_collider(root, Vector3(w, h, d))
		DOOR:
			var t := 0.1
			_part(root, _box_mesh(Vector3(t, h, d)), Vector3(-w * 0.5 + t * 0.5, 0, 0), m)
			_part(root, _box_mesh(Vector3(t, h, d)), Vector3(w * 0.5 - t * 0.5, 0, 0), m)
			_part(root, _box_mesh(Vector3(w, t, d)), Vector3(0, h * 0.5 - t * 0.5, 0), m)
			_studs(root, size.x, size.z, w, d, h * 0.5, m)
			if not ghost:
				_box_collider(root, Vector3(t, h, d), Vector3(-w * 0.5 + t * 0.5, 0, 0))
				_box_collider(root, Vector3(t, h, d), Vector3(w * 0.5 - t * 0.5, 0, 0))
				_box_collider(root, Vector3(w, t, d), Vector3(0, h * 0.5 - t * 0.5, 0))
			# the door itself swings on a hinge at the left edge
			var hinge := Node3D.new()
			hinge.name = "Hinge"
			hinge.position = Vector3(-w * 0.5 + t, -t * 0.5, 0)
			hinge.rotation.y = -PI * 0.5 if open else 0.0
			root.add_child(hinge)
			var panel_w := w - 2 * t
			var panel_h := h - t
			var panel: Node3D = Node3D.new() if ghost else StaticBody3D.new()
			panel.name = "Panel"
			panel.position = Vector3(panel_w * 0.5, 0, 0)
			hinge.add_child(panel)
			var pc := c.darkened(0.25)
			_part(panel, _box_mesh(Vector3(panel_w - 0.01, panel_h - 0.01, 0.1)), Vector3.ZERO, _mat(pc, ghost))
			_part(panel, _box_mesh(Vector3(0.06, 0.06, 0.16)), Vector3(panel_w * 0.5 - 0.15, 0, 0), _mat(Color(1.0, 0.8, 0.2), ghost))
			if not ghost:
				_box_collider(panel, Vector3(panel_w, panel_h, 0.1))
		_:
			_part(root, _box_mesh(Vector3(w - 0.006, h - 0.004, d - 0.006)), Vector3.ZERO, m)
			if shape != TILE:
				_studs(root, size.x, size.z, w, d, h * 0.5, m)
			if not ghost:
				_box_collider(root, Vector3(w, h, d))
	if ghost:
		_no_shadows(root)
	return root


static func _no_shadows(node: Node) -> void:
	for c in node.get_children():
		if c is GeometryInstance3D:
			c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_no_shadows(c)


static func tint_ghost(ghost: Node, c: Color) -> void:
	var m := _mat(c, true)
	for child in ghost.get_children():
		if child is MeshInstance3D and not (child.material_override as BaseMaterial3D).albedo_color.a < 0.3:
			child.material_override = m
		tint_ghost(child, c)


static func set_door_open(node: Node3D, open: bool) -> void:
	var hinge := node.get_node_or_null("Hinge") as Node3D
	if hinge:
		var tw := hinge.create_tween()
		tw.tween_property(hinge, "rotation:y", -PI * 0.5 if open else 0.0, 0.25)
