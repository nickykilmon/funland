extends RigidBody3D
# A physics prop or vehicle. Whoever "owns" it runs its physics and sends where it is;
# everyone else just glides it to those positions. Owners change when someone grabs,
# pushes or drives it (the host decides).

const Entities = preload("res://scripts/entities.gd")

const SPRING := 60.0  # suspension stiffness (per kg of vehicle)
const DAMP := 7.0     # suspension damping

var ent_id := 0
var type := 0
var owner_id := 1
var driver_id := 0
var main: Node
var cfg: Dictionary

var net_pos := Vector3.ZERO
var net_rot := Quaternion.IDENTITY
var net_vel := Vector3.ZERO
var has_net := false
var was_mine := false
var still_time := 0.0
var sent_asleep := false

var live_team := ""   # dodgeball: team that threw this ball, while it's still in the air
var wheel_nodes: Array[Node3D] = []
var rotor_speed := 0.0
var throttle := 0.0
var grounded := 0


func _ready() -> void:
	cfg = Entities.TYPES[type]
	collision_layer = 16
	collision_mask = 1 | 2 | 4 | 16
	mass = cfg["mass"]
	gravity_scale = main.gravity_scale()
	Entities.dress(self, type)
	for i in cfg.get("wheels", []).size():
		wheel_nodes.append(get_node("Wheel%d" % i))
	if cfg["kind"] != Entities.ITEM:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = Vector3(0, cfg.get("com_y", 0.0), 0)
		angular_damp = 0.5
	else:
		contact_monitor = true
		max_contacts_reported = 4
		body_entered.connect(_on_body_entered)
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	net_pos = position
	net_rot = quaternion
	_apply_owner()


func is_mine() -> bool:
	return owner_id == main.multiplayer.get_unique_id()


func set_owner_id(id: int) -> void:
	owner_id = id
	_apply_owner()


func _apply_owner() -> void:
	var mine := is_mine()
	freeze = not mine
	if mine and not was_mine:
		position = net_pos
		quaternion = net_rot
		linear_velocity = net_vel
		sleeping = false
		sent_asleep = false
	was_mine = mine


func net_update(pos: Vector3, rot: Quaternion, vel: Vector3) -> void:
	net_pos = pos
	net_rot = rot
	net_vel = vel
	if not has_net or position.distance_to(pos) > 15.0:
		position = pos
		quaternion = rot
	has_net = true


# Called by main a few times a second: returns this entity's state if it should be sent.
func state_to_send() -> Array:
	if not is_mine():
		return []
	if sleeping:
		if sent_asleep:
			return []
		sent_asleep = true
	else:
		sent_asleep = false
	return [ent_id, position, quaternion, linear_velocity]


func _physics_process(delta: float) -> void:
	if is_mine():
		if cfg["kind"] != Entities.ITEM:
			_vehicle(delta)
		if position.y < -40.0:
			position = main.entity_respawn_point()
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO
	else:
		var t := 1.0 - exp(-12.0 * delta)
		position = position.lerp(net_pos, t)
		quaternion = quaternion.slerp(net_rot, t)
		rotor_speed = move_toward(rotor_speed, 1.0 if driver_id != 0 else 0.0, delta * 0.6)
	_animate(delta)


func _on_body_entered(body: Node) -> void:
	if live_team == "" or not is_mine():
		return
	if body is CharacterBody3D and "peer_id" in body:
		if body.peer_id == main.multiplayer.get_unique_id():
			return
		main.report_ball_hit(ent_id, body.peer_id, live_team)
	elif body.has_meta("brick_id"):
		main.report_brick_hit(body.get_meta("brick_id"))
	live_team = ""


# ---------------- vehicles ----------------

func _vehicle(delta: float) -> void:
	var driving: bool = driver_id != 0 and driver_id == main.multiplayer.get_unique_id()
	var w := 0.0
	var s := 0.0
	var space_key := false
	var shift := false
	var ctrl := false
	var stick_y := 0.0   # controller left stick, up = +
	var rt := 0.0
	var lt := 0.0
	if driving and not (main.hud and (main.hud.is_typing() or main.hud.menu_open())):
		w = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		s = float(Input.is_physical_key_pressed(KEY_A)) - float(Input.is_physical_key_pressed(KEY_D))
		space_key = Input.is_physical_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A)
		shift = Input.is_physical_key_pressed(KEY_SHIFT)
		ctrl = Input.is_physical_key_pressed(KEY_CTRL)
		s = clampf(s - _stick(JOY_AXIS_LEFT_X), -1.0, 1.0)
		stick_y = -_stick(JOY_AXIS_LEFT_Y)
		rt = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT)
		lt = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT)
	# park: let a vehicle nobody is driving fall asleep once it has settled
	if not driving:
		if linear_velocity.length() < 0.08 and angular_velocity.length() < 0.08:
			still_time += delta
		else:
			still_time = 0.0
		if sleeping or still_time > 1.0:
			sleeping = true
			rotor_speed = move_toward(rotor_speed, 0.0, delta * 0.5)
			return
	else:
		sleeping = false
		still_time = 0.0
	match cfg["kind"]:
		Entities.CAR:
			# controller: right trigger gas, left trigger brake/reverse, A handbrake
			grounded = _suspension(delta, clampf(w + rt - lt, -1.0, 1.0), s, space_key or not driving, 8.0, true)
		Entities.HELI:
			# controller: left stick fly/turn, right trigger up, left trigger down
			grounded = _suspension(delta, 0.0, 0.0, true, 6.0, false)
			_heli(delta, driving, clampf(w + stick_y, -1.0, 1.0), s, (1.0 if space_key else 0.0) - (1.0 if shift else 0.0) + rt - lt)
		Entities.PLANE:
			# controller: left stick pitch/roll (push forward = nose down), triggers throttle
			grounded = _suspension(delta, 0.0, s, not driving or (w < 0 and throttle == 0.0), 6.0, false)
			_plane(delta, driving, clampf(w + stick_y, -1.0, 1.0), s, float(shift) + rt, float(ctrl) + lt)


# Raycast suspension: each wheel pushes the body up like a spring, grips sideways and drives forward.
func _suspension(_delta: float, drive: float, steer: float, brake: bool, grip: float, drives: bool) -> int:
	var space := get_world_3d().direct_space_state
	var b := global_basis
	var up := b.y
	var fwd := -b.z
	var speed := linear_velocity.dot(fwd)
	var r: float = cfg["wheel_r"]
	var rest: float = cfg["rest"]
	var wheels: Array = cfg["wheels"]
	var n := wheels.size()
	var steer_angle: float = steer * cfg.get("steer", 0.5) * clampf(1.0 - absf(speed) / 45.0, 0.35, 1.0)
	if drives:
		var top: float = cfg["top"]
		if (drive > 0 and speed > top) or (drive < 0 and speed < -top * 0.4):
			drive = 0.0
	var count := 0
	for i in n:
		var mount: Vector3 = wheels[i]
		var origin := global_transform * mount
		var q := PhysicsRayQueryParameters3D.create(origin, origin - up * (rest + r), 1 | 16, [get_rid()])
		var hit := space.intersect_ray(q)
		var wheel := wheel_nodes[i]
		var front := mount.z < 0.0
		if front:
			wheel.rotation.y = steer_angle
		if hit.is_empty():
			wheel.position = mount - Vector3(0, rest, 0)
			continue
		count += 1
		var dist := origin.distance_to(hit["position"])
		wheel.position = mount - Vector3(0, dist - r, 0)
		var offset := origin - global_position
		var pv := linear_velocity + angular_velocity.cross(offset)
		var comp := rest + r - dist
		var spring := comp * mass * SPRING * gravity_scale / n - up.dot(pv) * mass * DAMP * sqrt(gravity_scale) / n
		apply_force(up * maxf(spring, 0.0), offset)
		var wfwd := fwd.rotated(up, steer_angle) if front else fwd
		var wright := wfwd.cross(up)
		apply_force(-wright * pv.dot(wright) * mass * grip / n, offset)
		var along := pv.dot(wfwd)
		if drives and drive != 0.0:
			apply_force(wfwd * drive * mass * float(cfg["accel"]) / n, offset)
		if brake:
			apply_force(-wfwd * along * mass * 3.0 / n, offset)
		else:
			apply_force(-wfwd * along * mass * 0.15 / n, offset)
		var spin := wheel.get_node("Spin") as Node3D
		spin.rotation.x -= along / r * _delta
	return count


func _heli(delta: float, driving: bool, fwd_in: float, turn_in: float, lift_in: float) -> void:
	rotor_speed = move_toward(rotor_speed, 1.0 if driving else 0.0, delta * 0.6)
	if not driving or rotor_speed < 0.5:
		return
	var yaw := global_basis.get_euler().y
	var yaw_basis := Basis(Vector3.UP, yaw)
	var desired := yaw_basis * Vector3(0, lift_in * 7.0, -fwd_in * 18.0)
	var g := Vector3(0, -9.8 * gravity_scale, 0)
	apply_central_force((desired - linear_velocity) * mass * 1.5 - g * mass)
	# stay upright, leaning into the direction you fly
	var target := (yaw_basis * Basis(Vector3.RIGHT, -fwd_in * 0.22) * Basis(Vector3.BACK, turn_in * 0.1)).get_rotation_quaternion()
	var q := target * global_basis.get_rotation_quaternion().inverse()
	if q.w < 0.0:
		q = -q
	var correction := Vector3(q.x, q.y, q.z) * 2.0 * 5.0
	angular_velocity = angular_velocity.lerp(correction + Vector3.UP * turn_in * 1.6, 0.25)


func _plane(delta: float, driving: bool, pitch_in: float, roll_in: float, thr_up: float, thr_down: float) -> void:
	if driving:
		throttle = clampf(throttle + (minf(thr_up, 1.0) - minf(thr_down, 1.0)) * 0.6 * delta, 0.0, 1.0)
	else:
		throttle = move_toward(throttle, 0.0, delta)
	rotor_speed = throttle
	var b := global_basis
	var fwd := -b.z
	var speed := linear_velocity.dot(fwd)
	var takeoff := 22.0
	apply_central_force(fwd * throttle * mass * 14.0)
	var lift := clampf(speed / takeoff, 0.0, 1.3)
	apply_central_force(b.y * lift * lift * mass * 9.8 * gravity_scale)
	# arcade flight: the plane goes where its nose points
	var sideways := linear_velocity - fwd * speed
	apply_central_force(-sideways * mass * 0.9 * lift)
	apply_central_force(-linear_velocity * linear_velocity.length() * mass * 0.0055)
	if driving:
		var control := clampf(speed / takeoff, 0.15, 1.0)
		var local := Vector3(-pitch_in * 1.2, roll_in * 0.5, roll_in * 1.7) * control
		if grounded > 0:
			local.z = 0.0
		angular_velocity = angular_velocity.lerp(b * local, 0.12)


static func _stick(axis: JoyAxis) -> float:
	var v := Input.get_joy_axis(0, axis)
	return 0.0 if absf(v) < 0.2 else v


func flip_upright() -> void:
	var yaw := global_basis.get_euler().y
	quaternion = Quaternion(Vector3.UP, yaw)
	position += Vector3.UP * 1.5
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func _animate(delta: float) -> void:
	if cfg["kind"] == Entities.ITEM:
		return
	var rotor := get_node_or_null("Rotor") as Node3D
	if rotor:
		rotor.rotate_y(rotor_speed * delta * 28.0)
	var tail := get_node_or_null("TailRotor") as Node3D
	if tail:
		tail.rotate_x(rotor_speed * delta * 40.0)
	var prop := get_node_or_null("Prop") as Node3D
	if prop:
		prop.rotate_z(rotor_speed * delta * 45.0)
