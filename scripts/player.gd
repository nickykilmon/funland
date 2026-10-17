extends CharacterBody3D
# A funfig player. The local one reads input and owns the camera, hands (grab/throw),
# brick tool and driving; remote ones just glide toward the positions the network sends.

const Figure = preload("res://scripts/figure.gd")
const Bricks = preload("res://scripts/bricks.gd")
const Maps = preload("res://scripts/maps.gd")
const Entities = preload("res://scripts/entities.gd")

const WALK_SPEED := 5.0
const RUN_SPEED := 8.5
const JUMP_SPEED := 6.8
const MOUSE_SENS := 0.0025
const REACH := 9.0
const THIRD_PERSON_DIST := 3.5
const DEADZONE := 0.2
const STICK_LOOK := 3.2   # radians per second at full right-stick tilt
const TEAM_COLORS := {"red": Color(1.0, 0.35, 0.35), "blue": Color(0.45, 0.65, 1.0)}

enum { ANIM_NONE, ANIM_WAVE, ANIM_DANCE, ANIM_SIT }

var peer_id := 1
var info := {}
var is_local := false
var main: Node
var team := ""

var arm: SpringArm3D
var cam: Camera3D
var ray: RayCast3D
var fig: Node3D
var tag: Label3D
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

# hands: grabbing and throwing physics props
var held: RigidBody3D
var hold_dist := 2.5
var pending_grab := -1
var push_asked := {}   # entity id -> time we last asked to push it

# tool gun
var toolgun_on := false
var tool_mode := 0
var weld_first := -1
var wire_src := -1
var wire_mesh: MeshInstance3D

# driving
var vehicle: RigidBody3D
var remote_vehicle := -1

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

# controller
var pad_sprint := false
var rt_was := false
var lt_was := false

# swimming
var swimming := false
var underwater := false


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
		collision_mask = 1 | 4 | 8 | 16
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
		tag = Label3D.new()
		tag.text = str(info.get("name", "Player"))
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.position.y = 2.45
		tag.font_size = 40
		tag.outline_size = 10
		tag.pixel_size = 0.006
		add_child(tag)
	set_team(team)


func _exit_tree() -> void:
	if ghost:
		ghost.queue_free()


var disguise := -1


# Prop Hunt: show a prop instead of the funfig.
func set_disguise(type: int) -> void:
	if type == disguise:
		return
	disguise = type
	var old := get_node_or_null("Disguise")
	if old:
		old.queue_free()
	fig.visible = type < 0
	if tag:
		tag.visible = type < 0
	if type < 0:
		return
	var donor := RigidBody3D.new()
	Entities.dress(donor, type)
	var holder := Node3D.new()
	holder.name = "Disguise"
	holder.position.y = 0.5
	add_child(holder)
	for c in donor.get_children():
		donor.remove_child(c)
		if c is CollisionShape3D:
			c.free()
		else:
			holder.add_child(c)
	donor.free()
	if is_local:
		Figure.set_layers(holder, 2)
		_set_view(true)


func set_team(t: String) -> void:
	team = t
	if tag:
		tag.modulate = TEAM_COLORS.get(t, Color.WHITE)
		tag.text = ("[%s] " % t.to_upper() if t != "" else "") + str(info.get("name", "Player"))


func _set_view(third: bool) -> void:
	third_person = third
	var dist := THIRD_PERSON_DIST if third else 0.0
	if vehicle:
		dist = vehicle.cfg["cam"]
	arm.spring_length = dist
	arm.position.x = 0.45 if third and not vehicle else 0.0
	cam.cull_mask = 0xFFFFF if (third or vehicle) else 0xFFFFF & ~2
	ray.target_position = Vector3(0, 0, -(REACH + dist))


func net_update(pos: Vector3, yaw: float, a: int, veh: int) -> void:
	target_pos = pos
	target_yaw = yaw
	remote_vehicle = veh
	if a != anim:
		anim = a
		anim_time = 0.0
	if position.distance_to(pos) > 10.0:
		position = pos


func respawn() -> void:
	if vehicle:
		exit_vehicle()
	_drop()
	position = main.spawn_point_for(peer_id) + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	velocity = Vector3.ZERO


func knocked_out() -> void:
	respawn()
	main.audio.play("out")
	if main.hud:
		main.hud.big_message("You're out! Watch from the bench until the next round.")


func _physics_process(delta: float) -> void:
	if is_local:
		if vehicle:
			_seated_physics()
		else:
			_local_physics(delta)
	else:
		var e = main.entities.get(remote_vehicle) if remote_vehicle >= 0 else null
		if e:
			position = e.global_transform * (e.cfg["seat"] as Vector3)
			fig.global_basis = e.global_basis
		else:
			var t := 1.0 - exp(-14.0 * delta)
			position = position.lerp(target_pos, t)
			rotation.y = lerp_angle(rotation.y, target_yaw, t)
	var speed := Vector2(position.x - last_pos.x, position.z - last_pos.z).length() / maxf(delta, 0.0001)
	last_pos = position
	if (vehicle or remote_vehicle >= 0):
		speed = 0.0
	_animate(delta, speed)


func _local_physics(delta: float) -> void:
	var top: float = main.water_top(position + Vector3.UP * 1.1)
	var was_swimming := swimming
	swimming = not is_nan(top)
	if swimming and not was_swimming:
		main.progress.achieve("swim")
		if velocity.y < -3.0:
			main.audio.play("splash", position)
	underwater = not is_nan(main.water_top(cam.global_position))
	main.hud.set_underwater(underwater)
	if swimming:
		# tread water with your head above the surface
		velocity.y = move_toward(velocity.y, clampf((top - 1.45 - position.y) * 3.0, -2.5, 2.5), 10.0 * delta)
	elif not is_on_floor():
		velocity.y -= gravity * delta
	var typing: bool = main.hud != null and main.hud.is_typing()
	var input := Vector2.ZERO
	var jumped := false
	var menus: bool = typing or main.hud.menu_open() or not main.modes.can_move(peer_id)
	if not menus:
		if Input.is_physical_key_pressed(KEY_W): input.y -= 1
		if Input.is_physical_key_pressed(KEY_S): input.y += 1
		if Input.is_physical_key_pressed(KEY_A): input.x -= 1
		if Input.is_physical_key_pressed(KEY_D): input.x += 1
		input += Vector2(stick(JOY_AXIS_LEFT_X), stick(JOY_AXIS_LEFT_Y))
		input = input.limit_length(1.0)
		var jump_key := Input.is_physical_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A)
		if swimming:
			if jump_key:
				# swim up; near the surface, hop out
				velocity.y = JUMP_SPEED * 0.85 if position.y + 1.5 > top else 3.5
			elif Input.is_physical_key_pressed(KEY_CTRL) or Input.is_joy_button_pressed(0, JOY_BUTTON_B):
				velocity.y = -3.0
		elif jump_key and is_on_floor():
			velocity.y = JUMP_SPEED
			jumped = true
			main.audio.play("jump", null, -10.0)
	if input.length() < 0.1:
		pad_sprint = false
	if (input != Vector2.ZERO or jumped) and anim != ANIM_WAVE:
		anim = ANIM_NONE
	var running := not menus and (Input.is_physical_key_pressed(KEY_SHIFT) or pad_sprint)
	var speed := RUN_SPEED if running else WALK_SPEED
	if swimming:
		speed *= 0.6
	var dir := transform.basis * Vector3(input.x, 0, input.y)
	var accel := 50.0 if is_on_floor() else 15.0
	velocity.x = move_toward(velocity.x, dir.x * speed, accel * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, accel * delta)
	move_and_slide()
	_push_props()
	if position.y < -30.0 or _in_kill_zone():
		respawn()
	_send(delta, -1)
	_pad_look(delta)
	_pad_triggers(menus)
	_update_held()
	_update_ghost()
	_draw_wires()
	# hold the mouse button (or right trigger) to keep placing / painting
	var holding := (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) or (rt_was and not menus)
	if tool_on and holding:
		hold_timer -= delta
		if hold_timer <= 0.0:
			hold_timer = 0.1
			if paint_mode:
				_paint()
			elif place_pos != last_place_pos:
				_place()


func _send(delta: float, veh: int) -> void:
	send_timer += delta
	if send_timer >= 0.05:
		send_timer = 0.0
		main.send_transform(position, rotation.y, anim, veh)


# Walking into props shoves them (asking the host for control first if someone else runs them).
func _push_props() -> void:
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var body = c.get_collider()
		if not (body is RigidBody3D and "ent_id" in body):
			continue
		if body.is_mine():
			body.sleeping = false
			body.apply_central_impulse(-c.get_normal() * minf(body.mass, 40.0) * 0.2)
		elif body.driver_id == 0:
			var now := Time.get_ticks_msec()
			if now - int(push_asked.get(body.ent_id, 0)) > 600:
				push_asked[body.ent_id] = now
				main.request_own(body.ent_id)


func _in_kill_zone() -> bool:
	for area in get_tree().get_nodes_in_group("kill_zone"):
		if (area as Area3D).overlaps_body(self):
			return true
	return false


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
	var seated := vehicle != null or remote_vehicle >= 0
	match ANIM_SIT if seated else anim:
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
			arms = Vector2(0.5, 0.5) if not seated else Vector2(1.2, 1.2)
			body_y = -0.55 if not seated else 0.0
	if held and is_local:
		arms = Vector2(1.4, 1.4)
	_swing("LegL", legs.x)
	_swing("LegR", legs.y)
	_swing("ArmL", arms.x)
	_swing("ArmR", arms.y)
	var arm_r := fig.get_node_or_null("ArmR") as Node3D
	if arm_r:
		arm_r.rotation.z = lerpf(arm_r.rotation.z, arm_r_z, 0.3)
	fig.position.y = lerpf(fig.position.y, body_y, 0.3)
	if not seated:
		fig.rotation = Vector3(lerpf(fig.rotation.x, 0.0, 0.3), lerpf(fig.rotation.y, body_yaw, 0.2), lerpf(fig.rotation.z, 0.0, 0.3))
	var prop := fig.get_node_or_null("Propeller") as Node3D
	if prop:
		prop.rotate_y(delta * (6.0 + speed * 3.0))
	var pet := fig.get_node_or_null("Pet") as Node3D
	if pet:
		pet.position.y = 1.7 + sin(anim_time * 2.5 + peer_id) * 0.08
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
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		main.using_pad = true
	elif event is InputEventMouseButton or event is InputEventKey:
		main.using_pad = false
	if event is InputEventJoypadButton and event.pressed:
		if not main.hud.menu_open() or (event as InputEventJoypadButton).button_index == JOY_BUTTON_START:
			_pad_button((event as InputEventJoypadButton).button_index)
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
		if vehicle:
			return
		if toolgun_on:
			_toolgun_click(mb.button_index)
		elif tool_on:
			_tool_click(mb.button_index)
		else:
			_hands_click(mb.button_index)
	elif event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)


func _key(ke: InputEventKey) -> void:
	var key := ke.physical_keycode
	match key:
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		KEY_T, KEY_ENTER, KEY_KP_ENTER:
			get_viewport().set_input_as_handled()
			main.hud.open_chat()
		KEY_V:
			_set_view(not third_person)
		KEY_F:
			_use()
		KEY_M:
			main.audio.toggle_music()
	if vehicle:
		if key == KEY_R and vehicle.is_mine():
			vehicle.flip_upright()
		return
	match key:
		KEY_E:
			_toggle_tool()
		KEY_B:
			_spawn_menu()
		KEY_Y:
			_toggle_toolgun()
		KEY_Q:
			if toolgun_on:
				_tool_mode_step(-1 if ke.shift_pressed else 1)
			elif tool_on:
				_shape_step(-1 if ke.shift_pressed else 1)
		KEY_R:
			if tool_on:
				_rotate()
		KEY_P:
			paint_mode = not paint_mode
			tool_on = true
			_rebuild_ghost()
		KEY_Z:
			if ke.ctrl_pressed:
				main.request_undo()
			elif tool_on:
				_set_color(color_idx - 1)
		KEY_U:
			main.request_undo()
		KEY_X:
			if tool_on:
				_set_color(color_idx + 1)
			else:
				_delete_looked_at()
		KEY_G:
			_emote(ANIM_WAVE)
		KEY_H:
			_emote(ANIM_DANCE)
		KEY_C:
			_emote(ANIM_SIT)
		_:
			if main.modes.try_vote(key):
				return
			var sizes: Array = Bricks.SHAPES[shape]["sizes"]
			if tool_on and key >= KEY_1 and key <= KEY_9 and key - KEY_1 < sizes.size():
				size_idx[shape] = key - KEY_1
				_rebuild_ghost()


func _toggle_tool() -> void:
	tool_on = not tool_on
	if tool_on and toolgun_on:
		_toggle_toolgun()
	_drop()
	_rebuild_ghost()


func _toggle_toolgun() -> void:
	if main.is_dodgeball():
		return
	toolgun_on = not toolgun_on
	weld_first = -1
	wire_src = -1
	if toolgun_on and tool_on:
		tool_on = false
		_rebuild_ghost()
	_drop()
	_update_toolgun_hud()


func _tool_mode_step(d: int) -> void:
	tool_mode = posmod(tool_mode + d, main.TOOL_NAMES.size())
	weld_first = -1
	wire_src = -1
	_update_toolgun_hud()


func _update_toolgun_hud() -> void:
	var text := ""
	if toolgun_on:
		text = "TOOL GUN: %s   (Q to switch, Y to put away)\n%s" % [main.TOOL_NAMES[tool_mode], main.TOOL_HINTS[tool_mode]]
		if weld_first >= 0:
			text += "\nNow click the thing to weld it to"
		if wire_src >= 0:
			text += "\nNow click what it should control"
	main.hud.set_toolgun(text)


# What the crosshair is on: {entity, brick, point, normal} (entity/brick may be null/-1).
func _look_hit() -> Dictionary:
	var from := cam.global_position
	var to := from - cam.global_basis.z * (REACH + 6.0 + arm.spring_length)
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 16, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var out := {"entity": null, "brick": -1}
	if hit.is_empty():
		return out
	var body = hit["collider"]
	out["point"] = hit["position"]
	out["normal"] = hit["normal"]
	if body is RigidBody3D and "ent_id" in body:
		out["entity"] = body
	elif body is Node and body.has_meta("brick_id"):
		out["brick"] = body.get_meta("brick_id")
	return out


func _toolgun_click(button: int) -> void:
	if button != MOUSE_BUTTON_LEFT and button != MOUSE_BUTTON_RIGHT:
		return
	var alt := button == MOUSE_BUTTON_RIGHT
	var h := _look_hit()
	var e: RigidBody3D = h["entity"]
	main.audio.play("click", null, -10.0)
	if tool_mode == main.TOOL_WELD:
		if e == null:
			return
		if weld_first < 0:
			weld_first = e.ent_id
		else:
			if e.ent_id != weld_first:
				main.progress.achieve("welder")
				main.request_tool(main.TOOL_WELD, e.ent_id, Vector3.ZERO, Vector3.ZERO, weld_first)
			weld_first = -1
	elif tool_mode == main.TOOL_WIRE:
		if alt:
			if e:
				main.request_wire(e.ent_id, "", 0, true)
			wire_src = -1
		elif wire_src < 0:
			if e and (e.type == Entities.BUTTON or e.type == Entities.PLATE):
				wire_src = e.ent_id
		elif e and e.ent_id != wire_src:
			main.progress.achieve("electrician")
			main.request_wire(wire_src, "ent", e.ent_id)
			wire_src = -1
		elif h["brick"] >= 0:
			main.progress.achieve("electrician")
			main.request_wire(wire_src, "brick", h["brick"])
			wire_src = -1
	elif tool_mode == main.TOOL_REMOVER:
		if e:
			main.request_tool(main.TOOL_REMOVER, e.ent_id, Vector3.ZERO, Vector3.ZERO)
		elif h["brick"] >= 0:
			main.request_remove(h["brick"])
	elif e:
		if tool_mode == main.TOOL_BALLOON and not alt:
			main.progress.achieve("balloonist")
		elif tool_mode == main.TOOL_THRUSTER and not alt:
			main.progress.achieve("rocketeer")
		var inv: Transform3D = e.global_transform.affine_inverse()
		main.request_tool(tool_mode, e.ent_id, inv * (h["point"] as Vector3), inv.basis * (h["normal"] as Vector3), 0, alt)
	_update_toolgun_hud()


# Thin lines showing every wire while the wire tool is out.
func _draw_wires() -> void:
	var show: bool = toolgun_on and tool_mode == main.TOOL_WIRE
	if wire_mesh == null:
		wire_mesh = MeshInstance3D.new()
		wire_mesh.mesh = ImmediateMesh.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1.0, 0.85, 0.1)
		m.no_depth_test = true
		wire_mesh.material_override = m
		wire_mesh.top_level = true
		add_child(wire_mesh)
	var im := wire_mesh.mesh as ImmediateMesh
	im.clear_surfaces()
	if not show or main.wires.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for w in main.wires:
		var a = main.entities.get(w[0])
		var b_pos = null
		if w[1] == "ent" and main.entities.has(w[2]):
			b_pos = main.entities[w[2]].global_position
		elif w[1] == "brick" and main.bricks.has(w[2]):
			b_pos = main.bricks[w[2]][0]
		if a and b_pos != null:
			im.surface_add_vertex(a.global_position)
			im.surface_add_vertex(b_pos)
	im.surface_end()


func _spawn_menu() -> void:
	if not main.is_dodgeball():
		main.hud.toggle_spawn_menu()


func _shape_step(d: int) -> void:
	shape = posmod(shape + d, Bricks.SHAPES.size())
	_rebuild_ghost()


func _size_step(d: int) -> void:
	var sizes: Array = Bricks.SHAPES[shape]["sizes"]
	size_idx[shape] = posmod(size_idx[shape] + d, sizes.size())
	_rebuild_ghost()


func _rotate() -> void:
	rot = (rot + 1) % 4
	_rebuild_ghost()


# ---------------- Controller ----------------

static func stick(axis: JoyAxis) -> float:
	var v := Input.get_joy_axis(0, axis)
	return 0.0 if absf(v) < DEADZONE else v


func _pad_look(delta: float) -> void:
	var look := Vector2(stick(JOY_AXIS_RIGHT_X), stick(JOY_AXIS_RIGHT_Y))
	if look == Vector2.ZERO or main.hud.menu_open():
		return
	# a curve so small tilts aim finely and full tilt turns fast
	look = look * look.length()
	rotate_y(-look.x * STICK_LOOK * delta)
	pitch = clampf(pitch - look.y * STICK_LOOK * 0.7 * delta, -1.5, 1.5)
	arm.rotation.x = pitch


# Right trigger = left click, left trigger = right click (only on the press, like a mouse click).
func _pad_triggers(menus: bool) -> void:
	var rt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
	var lt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT) > 0.5
	if not menus and not vehicle:
		if rt and not rt_was:
			if toolgun_on:
				_toolgun_click(MOUSE_BUTTON_LEFT)
			elif tool_on:
				_tool_click(MOUSE_BUTTON_LEFT)
			else:
				_hands_click(MOUSE_BUTTON_LEFT)
		if lt and not lt_was:
			if toolgun_on:
				_toolgun_click(MOUSE_BUTTON_RIGHT)
			elif tool_on:
				_tool_click(MOUSE_BUTTON_RIGHT)
			else:
				_hands_click(MOUSE_BUTTON_RIGHT)
	rt_was = rt
	lt_was = lt


func _pad_button(b: int) -> void:
	match b:
		JOY_BUTTON_START:
			main.hud.toggle_pause()
			return
		JOY_BUTTON_X:
			_use()
			return
		JOY_BUTTON_RIGHT_STICK:
			_set_view(not third_person)
			return
	if vehicle:
		if b == JOY_BUTTON_Y and vehicle.is_mine():
			vehicle.flip_upright()
		return
	match b:
		JOY_BUTTON_Y:
			if toolgun_on:
				_toggle_toolgun()
			elif tool_on:
				_toggle_tool()
				_toggle_toolgun()
			else:
				_toggle_tool()
		JOY_BUTTON_B:
			if tool_on:
				main.request_undo()
			else:
				_delete_looked_at()
		JOY_BUTTON_BACK:
			_spawn_menu()
		JOY_BUTTON_LEFT_STICK:
			pad_sprint = not pad_sprint
		JOY_BUTTON_LEFT_SHOULDER:
			if tool_on:
				_set_color(color_idx - 1)
			else:
				_hands_click(MOUSE_BUTTON_WHEEL_DOWN)
		JOY_BUTTON_RIGHT_SHOULDER:
			if tool_on:
				_set_color(color_idx + 1)
			else:
				_hands_click(MOUSE_BUTTON_WHEEL_UP)
		JOY_BUTTON_DPAD_UP:
			if tool_on: _size_step(1)
			else: _emote(ANIM_WAVE)
		JOY_BUTTON_DPAD_DOWN:
			if tool_on: _size_step(-1)
			else: _emote(ANIM_SIT)
		JOY_BUTTON_DPAD_LEFT:
			if toolgun_on: _tool_mode_step(-1)
			elif tool_on: _shape_step(1)
			else: _emote(ANIM_DANCE)
		JOY_BUTTON_DPAD_RIGHT:
			if toolgun_on: _tool_mode_step(1)
			elif tool_on: _rotate()
			else:
				paint_mode = true
				tool_on = true
				_rebuild_ghost()


func _emote(a: int) -> void:
	if a == ANIM_DANCE:
		main.progress.achieve("dance")
	anim = ANIM_NONE if anim == a else a
	anim_time = 0.0
	if a == ANIM_SIT or a == ANIM_DANCE:
		velocity.x = 0
		velocity.z = 0


# F: open a door you're looking at, otherwise get in / out of the nearest vehicle.
func _use() -> void:
	if vehicle:
		exit_vehicle()
		return
	var id := _hit_brick_id()
	if id >= 0 and main.bricks.has(id) and main.bricks[id][3] == Bricks.DOOR:
		main.request_door(id)
		main.progress.achieve("first_door")
		return
	var looked := _look_entity()
	if looked and main.modes.mode == main.modes.PROP_HUNT and not main.modes.is_seeker(peer_id):
		main.modes.request_disguise(looked.type)
		return
	if looked and Entities.TYPES[looked.type].get("explosive", false):
		main.request_fuse(looked.ent_id)
		return
	if looked and (looked.type == Entities.BUTTON or looked.type == Entities.LAMP or not looked.state.get("thrusters", []).is_empty()):
		main.request_press(looked.ent_id)
		return
	var best: RigidBody3D = null
	var best_d := 4.5
	for e in main.entities.values():
		if Entities.is_vehicle(e.type) and e.driver_id == 0:
			var d: float = e.global_position.distance_to(global_position)
			if d < best_d:
				best_d = d
				best = e
	if best:
		main.request_drive(best.ent_id, true)


# ---------------- Driving ----------------

func enter_vehicle(e: RigidBody3D) -> void:
	_drop()
	tool_on = false
	_rebuild_ghost()
	vehicle = e
	main.progress.achieve("first_ride")
	collision_layer = 0
	collision_mask = 0
	arm.add_excluded_object(e.get_rid())
	anim = ANIM_SIT
	_set_view(third_person)
	if main.hud:
		main.hud.set_driving(e.cfg["kind"])


func exit_vehicle() -> void:
	var e := vehicle
	vehicle = null
	if is_instance_valid(e):
		main.request_drive(e.ent_id, false)
		arm.remove_excluded_object(e.get_rid())
		global_position = e.global_position + e.global_basis.x * -2.5 + Vector3.UP * 1.5
	collision_layer = 2
	collision_mask = 1 | 4 | 8 | 16
	anim = ANIM_NONE
	velocity = Vector3.ZERO
	_set_view(third_person)
	if main.hud:
		main.hud.set_driving(-1)


func _seated_physics() -> void:
	if not is_instance_valid(vehicle) or vehicle.driver_id != main.my_id():
		exit_vehicle()
		return
	global_position = vehicle.global_transform * (vehicle.cfg["seat"] as Vector3)
	velocity = Vector3.ZERO
	if (vehicle.cfg["kind"] == Entities.HELI or vehicle.cfg["kind"] == Entities.PLANE) and vehicle.grounded == 0 and vehicle.linear_velocity.length() > 5.0 and global_position.y > 10.0:
		main.progress.achieve("pilot")
	fig.global_basis = vehicle.global_basis
	_send(get_physics_process_delta_time(), vehicle.ent_id)
	_pad_look(get_physics_process_delta_time())


# ---------------- Hands: grab, drop, throw ----------------

func _look_entity() -> RigidBody3D:
	var from := cam.global_position
	var to := from - cam.global_basis.z * (REACH + arm.spring_length)
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | 16, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var body = hit["collider"]
	return body if body is RigidBody3D and "ent_id" in body else null


func _hands_click(button: int) -> void:
	if button == MOUSE_BUTTON_LEFT and main.modes.try_tag(self):
		return
	match button:
		MOUSE_BUTTON_LEFT:
			if held:
				_drop()
			else:
				_try_grab()
		MOUSE_BUTTON_RIGHT:
			if held:
				_throw()
		MOUSE_BUTTON_WHEEL_UP:
			hold_dist = minf(hold_dist + 0.5, 10.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			hold_dist = maxf(hold_dist - 0.5, 1.2)


func _try_grab() -> void:
	var e := _look_entity()
	if e == null or e.driver_id != 0:
		return
	if main.is_dodgeball() and not main.can_grab_balls():
		if main.hud:
			main.hud.big_message("You can grab balls once the round starts!" if main.alive.has(peer_id) else "You're out until the next round.")
		return
	if e.is_mine():
		_start_hold(e)
	else:
		pending_grab = e.ent_id
		main.request_own(e.ent_id)


func on_owner_changed(e: RigidBody3D) -> void:
	if e.ent_id == pending_grab and e.is_mine():
		pending_grab = -1
		_start_hold(e)
	elif held == e and not e.is_mine():
		held = null


func _start_hold(e: RigidBody3D) -> void:
	main.audio.play("grab", null, -8.0)
	held = e
	hold_dist = 1.4 if main.is_dodgeball() else clampf(cam.global_position.distance_to(e.global_position), 1.6, 8.0)


func _update_held() -> void:
	if held == null:
		return
	if not is_instance_valid(held) or not held.is_mine():
		held = null
		return
	var target := cam.global_position - cam.global_basis.z * hold_dist
	held.sleeping = false
	held.linear_velocity = ((target - held.global_position) * 14.0).limit_length(40.0)
	held.angular_velocity *= 0.8


func _drop() -> void:
	held = null
	pending_grab = -1


func _throw() -> void:
	if held == null or not is_instance_valid(held):
		return
	main.audio.play("throw", null, -6.0)
	main.progress.add("throws")
	var speed := clampf(60.0 / sqrt(held.mass), 6.0, 30.0)
	held.linear_velocity = -cam.global_basis.z * speed + velocity * 0.5
	if main.is_dodgeball():
		held.live_team = team
	held = null


func _delete_looked_at() -> void:
	var e := _look_entity()
	if e and e.driver_id == 0 and not main.is_dodgeball():
		main.request_delete(e.ent_id)


# Where to put something new from the spawn menu: on the ground a few steps in front of you.
func spawn_spot(type: int) -> Array:
	var vehicle_type := Entities.is_vehicle(type)
	var fwd := -global_basis.z
	var spot := global_position + fwd * (7.0 if vehicle_type else 3.0)
	var q := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 6.0, spot - Vector3.UP * 20.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		spot = hit["position"]
	spot += Vector3.UP * float(Entities.TYPES[type].get("rest_y", 0.6 if vehicle_type else 1.0))
	return [spot, rotation.y]


# ---------------- Funbrick tool ----------------

func _tool_click(button: int) -> void:
	match button:
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


func _hit_brick_id() -> int:
	if not ray.is_colliding():
		return -1
	var hit = ray.get_collider()
	if hit is Node and hit.has_meta("brick_id"):
		return hit.get_meta("brick_id")
	return -1


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
	if main.overlaps_any(place_pos, size, rot) or not main.can_build_here(peer_id, place_pos, size, rot):
		return false
	var me := AABB(position + Vector3(-0.35, 0.05, -0.35), Vector3(0.7, 1.8, 0.7))
	return not me.intersects(Bricks.box_of(place_pos, size, rot))


func _place() -> void:
	if ghost and ghost.visible and ghost_valid:
		main.progress.achieve("first_brick")
		main.progress.add("bricks")
		last_place_pos = place_pos
		main.request_place(place_pos, _brick_size(), Bricks.COLORS[color_idx], shape, rot)


func _paint() -> void:
	var id := _hit_brick_id()
	if id >= 0 and id != last_painted:
		main.progress.add("paints")
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
