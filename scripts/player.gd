extends CharacterBody3D
# A funfig player. The local one reads input and owns the camera + brick tool;
# remote ones just glide toward the positions the network sends.

const Figure = preload("res://scripts/figure.gd")
const Bricks = preload("res://scripts/bricks.gd")
const Maps = preload("res://scripts/maps.gd")

const WALK_SPEED := 5.0
const RUN_SPEED := 8.5
const JUMP_SPEED := 6.8
const MOUSE_SENS := 0.0025
const REACH := 9.0
const THIRD_PERSON_DIST := 3.5

enum { ANIM_NONE, ANIM_WAVE, ANIM_DANCE, ANIM_SIT }

var peer_id := 1
var info := {}
var is_local := false
var main: Node

var arm: SpringArm3D
var cam: Camera3D
var ray: RayCast3D
var fig: Node3D
var gravity := 18.0
var pitch := 0.0
var third_person := false
var walk_phase := 0.0
var anim := ANIM_NONE
var anim_time := 0.0
var target_pos := Vector3.ZERO
var target_yaw := 0.0
var send_timer := 0.0
var last_pos := Vector3.ZERO

# funbrick tool
var tool_on := false
var paint_mode := false
var shape := Bricks.BRICK
var size_idx := [7, 4, 3, 1, 0, 1, 0]  # chosen size for each shape
var color_idx := 0
var rot := 0
var ghost: Node3D
var ghost_valid := false
var place_pos := Vector3.ZERO
var last_place_pos := Vector3.INF
var last_painted := -1
var hold_timer := 0.0


func _ready() -> void:
	floor_max_angle = deg_to_rad(50)
	var shape_res := CapsuleShape3D.new()
	shape_res.radius = 0.35
	shape_res.height = 1.85
	var col := CollisionShape3D.new()
	col.shape = shape_res
	col.position.y = 0.925
	add_child(col)
	fig = Figure.build(info)
	add_child(fig)
	last_pos = position
	gravity = Maps.gravity(main.map_id)
	if is_local:
		collision_layer = 2
		collision_mask = 1 | 4
		Figure.set_layers(fig, 2)
		arm = SpringArm3D.new()
		arm.position.y = 1.62
		arm.spring_length = 0.0
		arm.collision_mask = 1
		arm.margin = 0.2
		arm.add_excluded_object(get_rid())
		add_child(arm)
		cam = Camera3D.new()
		cam.fov = 75
		arm.add_child(cam)
		cam.make_current()
		ray = RayCast3D.new()
		ray.collision_mask = 1
		cam.add_child(ray)
		_set_view(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		collision_layer = 4
		collision_mask = 0
		var tag := Label3D.new()
		tag.text = str(info.get("name", "Player"))
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.position.y = 2.45
		tag.font_size = 40
		tag.outline_size = 10
		tag.pixel_size = 0.006
		add_child(tag)


func _exit_tree() -> void:
	if ghost:
		ghost.queue_free()


func _set_view(third: bool) -> void:
	third_person = third
	arm.spring_length = THIRD_PERSON_DIST if third else 0.0
	arm.position.x = 0.45 if third else 0.0
	cam.cull_mask = 0xFFFFF if third else 0xFFFFF & ~2
	ray.target_position = Vector3(0, 0, -(REACH + (THIRD_PERSON_DIST if third else 0.0)))


func net_update(pos: Vector3, yaw: float, a: int) -> void:
	target_pos = pos
	target_yaw = yaw
	if a != anim:
		anim = a
		anim_time = 0.0
	if position.distance_to(pos) > 10.0:
		position = pos


func _physics_process(delta: float) -> void:
	if is_local:
		_local_physics(delta)
	else:
		var t := 1.0 - exp(-14.0 * delta)
		position = position.lerp(target_pos, t)
		rotation.y = lerp_angle(rotation.y, target_yaw, t)
	var speed := Vector2(position.x - last_pos.x, position.z - last_pos.z).length() / maxf(delta, 0.0001)
	last_pos = position
	_animate(delta, speed)


func _local_physics(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	var typing: bool = main.hud != null and main.hud.is_typing()
	var input := Vector2.ZERO
	var jumped := false
	if not typing:
		if Input.is_physical_key_pressed(KEY_W): input.y -= 1
		if Input.is_physical_key_pressed(KEY_S): input.y += 1
		if Input.is_physical_key_pressed(KEY_A): input.x -= 1
		if Input.is_physical_key_pressed(KEY_D): input.x += 1
		if Input.is_physical_key_pressed(KEY_SPACE) and is_on_floor():
			velocity.y = JUMP_SPEED
			jumped = true
	if (input != Vector2.ZERO or jumped) and anim != ANIM_WAVE:
		anim = ANIM_NONE
	var speed := RUN_SPEED if not typing and Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
	var dir := (transform.basis * Vector3(input.x, 0, input.y)).normalized()
	var accel := 50.0 if is_on_floor() else 15.0
	velocity.x = move_toward(velocity.x, dir.x * speed, accel * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, accel * delta)
	move_and_slide()
	if position.y < -30.0 or _in_kill_zone():
		respawn()
	send_timer += delta
	if send_timer >= 0.05:
		send_timer = 0.0
		main.send_transform(position, rotation.y, anim)
	_update_ghost()
	# hold the mouse button to keep placing / painting
	if tool_on and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		hold_timer -= delta
		if hold_timer <= 0.0:
			hold_timer = 0.1
			if paint_mode:
				_paint()
			elif place_pos != last_place_pos:
				_place()


func _in_kill_zone() -> bool:
	for area in get_tree().get_nodes_in_group("kill_zone"):
		if (area as Area3D).overlaps_body(self):
			return true
	return false


func respawn() -> void:
	position = Maps.spawn_point(main.map_id) + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	velocity = Vector3.ZERO


func _animate(delta: float, speed: float) -> void:
	anim_time += delta
	if anim == ANIM_WAVE and anim_time > 2.5:
		anim = ANIM_NONE
	var amount := clampf(speed / RUN_SPEED, 0.0, 1.0)
	if speed > 0.3:
		walk_phase += delta * (5.0 + speed)
	var swing := sin(walk_phase) * 0.8 * amount
	var legs := Vector2(swing, -swing)
	var arms := Vector2(-swing * 0.8, swing * 0.8)
	var arm_r_z := 0.0
	var body_y := 0.0
	var body_yaw := 0.0
	match anim:
		ANIM_WAVE:
			arms.y = 2.8
			arm_r_z = 0.3 + sin(anim_time * 12.0) * 0.35
		ANIM_DANCE:
			var t := anim_time * 8.0
			arms = Vector2(2.6 + sin(t) * 0.5, 2.6 - sin(t) * 0.5)
			legs = Vector2(sin(t) * 0.4, -sin(t) * 0.4)
			body_y = absf(sin(t)) * 0.12
			body_yaw = sin(anim_time * 4.0) * 0.5
		ANIM_SIT:
			legs = Vector2(PI * 0.5, PI * 0.5)
			arms = Vector2(0.5, 0.5)
			body_y = -0.55
	_swing("LegL", legs.x)
	_swing("LegR", legs.y)
	_swing("ArmL", arms.x)
	_swing("ArmR", arms.y)
	var arm_r := fig.get_node_or_null("ArmR") as Node3D
	if arm_r:
		arm_r.rotation.z = lerpf(arm_r.rotation.z, arm_r_z, 0.3)
	fig.position.y = lerpf(fig.position.y, body_y, 0.3)
	fig.rotation.y = lerpf(fig.rotation.y, body_yaw, 0.2)
	var prop := fig.get_node_or_null("Propeller") as Node3D
	if prop:
		prop.rotate_y(delta * (6.0 + speed * 3.0))
	var cape := fig.get_node_or_null("Cape") as Node3D
	if cape:
		cape.rotation.x = lerpf(cape.rotation.x, 0.08 + amount * 0.7 + sin(walk_phase * 0.5) * 0.05 * amount, 0.1)


func _swing(part: String, angle: float) -> void:
	var node := fig.get_node_or_null(part) as Node3D
	if node:
		node.rotation.x = lerpf(node.rotation.x, angle, 0.3)


func _unhandled_input(event: InputEvent) -> void:
	if not is_local:
		return
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and captured:
		var mm := event as InputEventMouseMotion
		rotate_y(-mm.relative.x * MOUSE_SENS)
		pitch = clampf(pitch - mm.relative.y * MOUSE_SENS, -1.5, 1.5)
		arm.rotation.x = pitch
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if not captured:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if not tool_on:
			return
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				hold_timer = 0.35
				last_place_pos = Vector3.INF
				last_painted = -1
				if paint_mode:
					_paint()
				else:
					_place()
			MOUSE_BUTTON_RIGHT: _remove()
			MOUSE_BUTTON_MIDDLE: _copy()
			MOUSE_BUTTON_WHEEL_UP: _set_color(color_idx - 1)
			MOUSE_BUTTON_WHEEL_DOWN: _set_color(color_idx + 1)
	elif event is InputEventKey and event.pressed and not event.echo:
		var ke := event as InputEventKey
		var key := ke.physical_keycode
		match key:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_E:
				tool_on = not tool_on
				_rebuild_ghost()
			KEY_Q:
				shape = posmod(shape + (-1 if ke.shift_pressed else 1), Bricks.SHAPES.size())
				_rebuild_ghost()
			KEY_R:
				rot = (rot + 1) % 4
				_rebuild_ghost()
			KEY_P:
				paint_mode = not paint_mode
				if not tool_on:
					tool_on = true
				_rebuild_ghost()
			KEY_Z:
				if ke.ctrl_pressed:
					main.request_undo()
				else:
					_set_color(color_idx - 1)
			KEY_U:
				main.request_undo()
			KEY_X:
				_set_color(color_idx + 1)
			KEY_F:
				_use_door()
			KEY_G:
				_emote(ANIM_WAVE)
			KEY_H:
				_emote(ANIM_DANCE)
			KEY_C:
				_emote(ANIM_SIT)
			KEY_V:
				_set_view(not third_person)
			KEY_T, KEY_ENTER, KEY_KP_ENTER:
				get_viewport().set_input_as_handled()
				main.hud.open_chat()
			_:
				var sizes: Array = Bricks.SHAPES[shape]["sizes"]
				if key >= KEY_1 and key <= KEY_9 and key - KEY_1 < sizes.size():
					size_idx[shape] = key - KEY_1
					_rebuild_ghost()


func _emote(a: int) -> void:
	anim = ANIM_NONE if anim == a else a
	anim_time = 0.0
	if a == ANIM_SIT or a == ANIM_DANCE:
		velocity.x = 0
		velocity.z = 0


func _hit_brick_id() -> int:
	if not ray.is_colliding():
		return -1
	var hit = ray.get_collider()
	if hit is Node and hit.has_meta("brick_id"):
		return hit.get_meta("brick_id")
	return -1


func _use_door() -> void:
	var id := _hit_brick_id()
	if id >= 0 and main.bricks.has(id) and main.bricks[id][3] == Bricks.DOOR:
		main.request_door(id)


# ---------------- Funbrick tool ----------------

func _set_color(i: int) -> void:
	color_idx = posmod(i, Bricks.COLORS.size())
	_rebuild_ghost()


func _brick_size() -> Vector3i:
	return Bricks.size_for(shape, size_idx[shape])


func _rebuild_ghost() -> void:
	if ghost:
		ghost.queue_free()
		ghost = null
	if tool_on and not paint_mode:
		ghost = Bricks.make(shape, _brick_size(), Bricks.COLORS[color_idx], true)
		ghost.rotation.y = rot * PI * 0.5
		ghost.visible = false
		main.add_child(ghost)
		ghost_valid = true
	if main.hud:
		main.hud.set_tool(tool_on, paint_mode, Bricks.SHAPES[shape]["name"], _brick_size(), rot, color_idx)


func _update_ghost() -> void:
	if ghost == null:
		return
	if not ray.is_colliding():
		ghost.visible = false
		return
	var valid := _compute_place()
	ghost.visible = true
	ghost.position = place_pos
	if valid != ghost_valid:
		ghost_valid = valid
		Bricks.tint_ghost(ghost, Bricks.COLORS[color_idx] if valid else Color(1, 0.15, 0.15))


# Works out where the brick would go from what the crosshair is pointing at. Returns false if it can't go there.
func _compute_place() -> bool:
	var p := ray.get_collision_point()
	var n := ray.get_collision_normal()
	var size := _brick_size()
	var ext := Bricks.extents(size, rot)
	var half := ext * 0.5
	var base_y := p.y
	var q := p
	if n.y > 0.7:
		var snap := roundf(p.y / Bricks.PLATE) * Bricks.PLATE
		if absf(snap - p.y) < 0.05:
			base_y = snap
	elif n.y < -0.7:
		base_y = p.y - ext.y
	else:
		var id := _hit_brick_id()
		if id >= 0 and main.bricks.has(id):
			var rec: Array = main.bricks[id]
			base_y = rec[0].y - Bricks.extents(rec[1], rec[4]).y * 0.5
		else:
			base_y = floorf(p.y / Bricks.PLATE) * Bricks.PLATE
		q.x += n.x * (half.x + 0.01)
		q.z += n.z * (half.z + 0.01)
	var fx := roundi(ext.x / Bricks.STUD)
	var fz := roundi(ext.z / Bricks.STUD)
	var ix := roundf(q.x / Bricks.STUD - fx * 0.5)
	var iz := roundf(q.z / Bricks.STUD - fz * 0.5)
	place_pos = Vector3((ix + fx * 0.5) * Bricks.STUD, base_y + half.y, (iz + fz * 0.5) * Bricks.STUD)
	if main.overlaps_any(place_pos, size, rot):
		return false
	var me := AABB(position + Vector3(-0.35, 0.05, -0.35), Vector3(0.7, 1.8, 0.7))
	return not me.intersects(Bricks.box_of(place_pos, size, rot))


func _place() -> void:
	if ghost and ghost.visible and ghost_valid:
		last_place_pos = place_pos
		main.request_place(place_pos, _brick_size(), Bricks.COLORS[color_idx], shape, rot)


func _paint() -> void:
	var id := _hit_brick_id()
	if id >= 0 and id != last_painted:
		last_painted = id
		main.request_paint(id, Bricks.COLORS[color_idx])


func _remove() -> void:
	var id := _hit_brick_id()
	if id >= 0:
		main.request_remove(id)


# Middle click: pick up the shape, size, rotation and color of the brick you're looking at.
func _copy() -> void:
	var id := _hit_brick_id()
	if id < 0 or not main.bricks.has(id):
		return
	var rec: Array = main.bricks[id]
	shape = rec[3]
	var sizes: Array = Bricks.SHAPES[shape]["sizes"]
	var idx := sizes.find(Vector2i(rec[1].x, rec[1].z))
	size_idx[shape] = maxi(idx, 0)
	rot = rec[4]
	var best := 0
	var best_d := INF
	for i in Bricks.COLORS.size():
		var c: Color = Bricks.COLORS[i]
		var d := Vector3(c.r - rec[2].r, c.g - rec[2].g, c.b - rec[2].b).length()
		if d < best_d:
			best_d = d
			best = i
	color_idx = best
	paint_mode = false
	_rebuild_ghost()
