extends RefCounted
# Merges lots of small static meshes into a few big ones (one per area of the world),
# so the graphics card draws a handful of objects instead of thousands. Looks identical:
# each part keeps its color as a vertex color.

const CELL := 32.0

static var _mat: StandardMaterial3D


static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.roughness = 0.3
	return _mat


# Plain opaque single-color parts can be merged; glass, glowing, textured ones stay separate.
static func can_merge(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or mi.has_meta("nomerge"):
		return false
	var m := mi.material_override as StandardMaterial3D
	if m == null:
		return false
	return m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
		and not m.emission_enabled and m.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL


static func relative_xform(n: Node3D, root: Node) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != root and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


class Group:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func add(mesh: Mesh, t: Transform3D, c: Color) -> void:
		var nt := Transform3D(t.basis.inverse().transposed(), Vector3.ZERO)
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var base := verts.size()
			verts.append_array(t * v)
			normals.append_array(nt * n)
			var cols := PackedColorArray()
			cols.resize(v.size())
			cols.fill(c)
			colors.append_array(cols)
			var idx = arr[Mesh.ARRAY_INDEX]
			if idx == null or (idx as PackedInt32Array).is_empty():
				for i in v.size():
					indices.append(base + i)
			elif base == 0:
				indices.append_array(idx)
			else:
				for i in idx:
					indices.append(base + i)

	func to_mesh(mat: Material) -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_material(0, mat)
		return am


# Bakes every mergeable mesh under root into one mesh per CELL-sized area and deletes the originals.
static func merge(root: Node3D) -> void:
	var groups := {}
	var merged: Array[MeshInstance3D] = []
	_collect(root, root, groups, merged)
	for mi in merged:
		mi.get_parent().remove_child(mi)
		mi.free()
	for key in groups:
		var mi := MeshInstance3D.new()
		mi.name = "Merged"
		# textured parts (world-mapped studs) keep their own material; plain ones share the vertex-color one
		mi.mesh = groups[key].to_mesh(key[1] if key[1] != null else material())
		root.add_child(mi)


static func _collect(node: Node, root: Node3D, groups: Dictionary, merged: Array[MeshInstance3D]) -> void:
	for c in node.get_children():
		if c is MeshInstance3D and c.visible and can_merge(c):
			var t := relative_xform(c, root)
			var m := c.material_override as StandardMaterial3D
			var key := [Vector3i((t.origin / CELL).floor()), m if m.albedo_texture != null else null]
			if not groups.has(key):
				groups[key] = Group.new()
			groups[key].add(c.mesh, t, (c.material_override as StandardMaterial3D).albedo_color)
			merged.append(c)
		_collect(c, root, groups, merged)
