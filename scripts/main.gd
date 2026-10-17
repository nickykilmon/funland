extends Node3D
# FunLand main: menu, networking (host + join), shared world state (players, funbricks, physics props
# and vehicles), dodgeball rounds, chat and saving.
# The host is the boss: clients ask it to place/remove/paint bricks, spawn things or chat, and it tells everyone.

const ONLINE_URL := "wss://funland.onrender.com/ws"
const MAX_BRICKS := 20000
const MAX_ENTITIES := 150
const MAX_ENTITIES_PER_PLAYER := 30
const BUILDS_DIR := "user://builds"
const BRICK_CELL := 2.0     # spatial grid for overlap checks
const CHUNK := 8.0          # bricks are drawn merged per 8 m chunk
const ENT_SEND_RATE := 15.0

const DODGE_BALLS := 12
const DODGE_BRICKS := 30
const BUILD_TIME := 10.0
const ROUND_OVER_TIME := 4.0

const Maps = preload("res://scripts/maps.gd")
const Bricks = preload("res://scripts/bricks.gd")
const Figure = preload("res://scripts/figure.gd")
const Entities = preload("res://scripts/entities.gd")
const Batcher = preload("res://scripts/batcher.gd")
const PlayerScript = preload("res://scripts/player.gd")
const EntityScript = preload("res://scripts/entity.gd")
const MenuScript = preload("res://scripts/menu.gd")
const HudScript = preload("res://scripts/hud.gd")
const RelayPeer = preload("res://scripts/relay_peer.gd")
const AudioScript = preload("res://scripts/audio.gd")

const EXPLOSION_RADIUS := 4.0
const BLAST_RADIUS := 9.0

var menu: CanvasLayer
var hud: CanvasLayer
var world: Node3D
var brick_root: Node3D
var chunk_root: Node3D
var player_root: Node3D
var entity_root: Node3D
var in_game := false

var my_info := {}
var players := {}       # peer id -> info dictionary
var player_nodes := {}  # peer id -> player node
var teams := {}         # peer id -> "red" / "blue" (dodgeball)
var bricks := {}        # brick id -> [pos, size, color, shape, rot]
var brick_nodes := {}   # brick id -> brick node
var brick_cells := {}   # grid cell -> brick ids touching it
var chunk_ids := {}     # chunk -> brick ids drawn in it
var chunk_meshes := {}  # chunk -> merged MeshInstance3D
var dirty_chunks := {}
var doors_open := {}    # brick id -> true for open doors
var history := {}       # peer id -> brick ids they placed (host only, for undo)
var brick_owner := {}   # brick id -> peer who placed it (host only)
var brick_count := {}   # peer id -> bricks they have placed (host only, for limits)
var brick_hp := {}      # brick id -> hits left (dodgeball, host only)
var brick_limit := 0    # bricks per player, 0 = unlimited
var next_brick_id := 1
var entities := {}      # entity id -> entity node
var ent_spawner := {}   # entity id -> peer who spawned it (host only)
var next_ent_id := 1
var ent_send_timer := 0.0
var pending_ents := []  # entities from a loaded build, spawned once the world exists
var pending_wires := []
var map_id := 0
var plane_color := Color(0.3, 0.68, 0.25)
var room_code := ""
var loaded_build := ""
var list_ws: WebSocketPeer
var list_sent := false
var auto_join := false
var using_pad := false
var test_mode := false   # headless test runs: no captured mouse, so don't auto-pause
var audio: Node
var water_boxes: Array = []   # [AABB, surface y]
var fuses := {}               # host: explosive entity id -> seconds left
var wires: Array = []         # [source entity id, "ent"/"brick", target id]
var plate_timer := 0.0

# dodgeball (decided by the host, copied to everyone)
var dodge_state := "waiting"   # waiting / build / playing / roundover
var dodge_timer := 0.0
var score := {"red": 0, "blue": 0}
var alive := {}                # peer id -> true while still in this round


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_add_pad_ui_controls()
	audio = AudioScript.new()
	add_child(audio)
	menu = MenuScript.new()
	add_child(menu)
	menu.host_requested.connect(host_game)
	menu.join_requested.connect(join_game)
	_handle_test_args()


# Lets a controller click buttons (A), go back (B) and move around menus (d-pad / left stick).
func _add_pad_ui_controls() -> void:
	var binds := {
		"ui_accept": [JOY_BUTTON_A], "ui_cancel": [JOY_BUTTON_B],
		"ui_up": [JOY_BUTTON_DPAD_UP], "ui_down": [JOY_BUTTON_DPAD_DOWN],
		"ui_left": [JOY_BUTTON_DPAD_LEFT], "ui_right": [JOY_BUTTON_DPAD_RIGHT],
	}
	for action in binds:
		for b in binds[action]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = b
			if not InputMap.action_has_event(action, ev):
				InputMap.action_add_event(action, ev)
	for pair in [["ui_up", JOY_AXIS_LEFT_Y, -1.0], ["ui_down", JOY_AXIS_LEFT_Y, 1.0], ["ui_left", JOY_AXIS_LEFT_X, -1.0], ["ui_right", JOY_AXIS_LEFT_X, 1.0]]:
		var m := InputEventJoypadMotion.new()
		m.axis = pair[1]
		m.axis_value = pair[2]
		if not InputMap.action_has_event(pair[0], m):
			InputMap.action_add_event(pair[0], m)


func is_dodgeball() -> bool:
	return map_id == Maps.DODGEBALL


func gravity_scale() -> float:
	return Maps.gravity(map_id) / 9.8


func my_id() -> int:
	return multiplayer.get_unique_id()


func local_player() -> Node:
	return player_nodes.get(my_id())


# ---------------- Starting / leaving ----------------

# The relay server lives on the same website the web build is served from.
func server_url() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("server="):
			return a.trim_prefix("server=")
	if OS.has_feature("web"):
		var secure: bool = JavaScriptBridge.eval("location.protocol") == "https:"
		return ("wss://" if secure else "ws://") + str(JavaScriptBridge.eval("location.host")) + "/ws"
	return ONLINE_URL


func host_game(info: Dictionary, map: int, color: Color, build_name := "", limit := 0) -> void:
	my_info = clean_info(info)
	map_id = clampi(map, 0, Maps.NAMES.size() - 1)
	plane_color = color
	brick_limit = maxi(limit, 0)
	loaded_build = ""
	if build_name != "":
		var count := _load_build(build_name)
		if count >= 0:
			loaded_build = "Loaded build \"%s\" (%d bricks)." % [build_name, count]
	var peer := RelayPeer.new()
	peer.room_ready.connect(_on_room_ready)
	peer.relay_error.connect(_on_relay_error)
	if peer.start(server_url(), {"t": "host", "name": my_info["name"], "map": Maps.NAMES[map_id]}) != OK:
		menu.set_status("Couldn't start connecting to the FunLand server.")
		return
	multiplayer.multiplayer_peer = peer
	menu.set_status("Creating a room...")


func _on_room_ready(code: String) -> void:
	room_code = code
	if not multiplayer.is_server():
		return
	players[1] = my_info
	_start_world()
	var first_ent := next_ent_id
	for e in pending_ents:
		_add_entity(next_ent_id, e[0], e[1], e[2], 1, 0, e[3])
		ent_spawner[next_ent_id - 1] = 1
	for w in pending_wires:
		var bids: Array = w[3]
		if w[1] == "ent":
			wires.append([first_ent + w[0], "ent", first_ent + w[2]])
		elif w[2] < bids.size():
			wires.append([first_ent + w[0], "brick", bids[w[2]]])
	pending_ents.clear()
	pending_wires.clear()
	_spawn_player(1, my_info)
	hud.is_host = true
	hud.set_room(code)
	hud.add_system("Your room code is %s. Friends find it in the room list on the start screen." % code)
	if loaded_build != "":
		hud.add_system(loaded_build)
	if brick_limit > 0 and not is_dodgeball():
		hud.add_system("Brick limit: %d per player." % brick_limit)
	brick_budget(_budget_left(1))
	if is_dodgeball():
		hud.add_system("Dodgeball! Pick a team. Each round starts with %d seconds to build defenses (%d bricks each)." % [BUILD_TIME, DODGE_BRICKS])


func join_game(info: Dictionary, code: String) -> void:
	code = code.strip_edges().to_upper()
	if code == "":
		menu.set_status("Pick a room from the list or type its code.")
		return
	my_info = clean_info(info)
	var peer := RelayPeer.new()
	peer.room_ready.connect(_on_room_ready)
	peer.relay_error.connect(_on_relay_error)
	if peer.start(server_url(), {"t": "join", "room": code}) != OK:
		menu.set_status("Couldn't start connecting to the FunLand server.")
		return
	multiplayer.multiplayer_peer = peer
	menu.set_status("Joining room %s..." % code)


func back_to_menu(msg := "") -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	if msg != "":
		Engine.set_meta("menu_msg", msg)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


# Asks the server which rooms are open; the answer goes to the menu's room list.
func fetch_rooms() -> void:
	list_ws = WebSocketPeer.new()
	list_sent = false
	if list_ws.connect_to_url(server_url()) != OK:
		list_ws = null


func _process(delta: float) -> void:
	_poll_room_list()
	for key in dirty_chunks:
		_rebuild_chunk(key)
	dirty_chunks.clear()
	if in_game and is_dodgeball():
		dodge_timer = maxf(dodge_timer - delta, 0.0)
		if multiplayer.is_server():
			_dodge_tick()
		if hud:
			hud.set_dodge(dodge_state, dodge_timer, score, _alive_count("red"), _alive_count("blue"), teams.get(my_id(), ""))


# Surface height of the water at this point, or NAN if it's not in water.
func water_top(p: Vector3) -> float:
	for w in water_boxes:
		if (w[0] as AABB).has_point(p):
			return w[1]
	return NAN


func _physics_process(delta: float) -> void:
	if not in_game:
		return
	if multiplayer.is_server():
		plate_timer -= delta
		if plate_timer <= 0.0:
			plate_timer = 0.2
			_check_plates()
		for id in fuses.keys():
			fuses[id] -= delta
			if fuses[id] <= 0.0:
				fuses.erase(id)
				_server_explode(id)
	ent_send_timer += delta
	if ent_send_timer < 1.0 / ENT_SEND_RATE:
		return
	ent_send_timer = 0.0
	var states := []
	for e in entities.values():
		var s: Array = e.state_to_send()
		if not s.is_empty():
			states.append(s)
	if not states.is_empty():
		sync_ents.rpc(states)


func _poll_room_list() -> void:
	if list_ws == null:
		return
	list_ws.poll()
	var state := list_ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not list_sent:
		list_ws.send_text(JSON.stringify({"t": "list"}))
		list_sent = true
	while list_ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(list_ws.get_packet().get_string_from_utf8())
		if msg is Dictionary and msg.get("t") == "rooms":
			list_ws.close()
			_on_rooms(msg.get("rooms", []))
	if state == WebSocketPeer.STATE_CLOSED:
		if not list_sent and is_instance_valid(menu):
			menu.show_rooms(null)
		list_ws = null


func _on_rooms(rooms: Array) -> void:
	if auto_join and rooms.size() > 0:
		auto_join = false
		join_game({"name": "Joiner", "hat": 13, "acc": 2, "face": 4}, rooms[0]["code"])
	if is_instance_valid(menu):
		menu.show_rooms(rooms)


func _start_world() -> void:
	if in_game:
		return
	in_game = true
	if is_instance_valid(menu):
		menu.queue_free()
	world = Maps.build(map_id, plane_color)
	add_child(world)
	for w in get_tree().get_nodes_in_group("water"):
		var size: Vector3 = ((w.get_child(0) as CollisionShape3D).shape as BoxShape3D).size
		water_boxes.append([AABB(w.position - size * 0.5, size), w.get_meta("top")])
	audio.start_music(map_id)
	brick_root = Node3D.new()
	brick_root.name = "Bricks"
	add_child(brick_root)
	chunk_root = Node3D.new()
	chunk_root.name = "BrickChunks"
	add_child(chunk_root)
	entity_root = Node3D.new()
	entity_root.name = "Entities"
	add_child(entity_root)
	player_root = Node3D.new()
	player_root.name = "Players"
	add_child(player_root)
	hud = HudScript.new()
	add_child(hud)
	hud.chat_sent.connect(send_chat)
	hud.leave_pressed.connect(back_to_menu)
	hud.save_pressed.connect(_on_save_pressed)
	hud.spawn_chosen.connect(_on_spawn_chosen)
	hud.team_chosen.connect(request_team)
	hud.clear_pressed.connect(func():
		if multiplayer.is_server():
			_clear_all_bricks()
			system_msg.rpc("The host cleared all the bricks."))
	hud.set_dodgeball(is_dodgeball())
	for id in bricks:
		_make_brick_node(id)


func clean_info(info: Dictionary) -> Dictionary:
	var n := str(info.get("name", "")).strip_edges().left(16)
	if n == "":
		n = "Player%d" % randi_range(100, 999)
	var out := {"name": n}
	for key in Figure.COLOR_DEFAULTS:
		var c = info.get(key)
		out[key] = c if c is Color else Figure.COLOR_DEFAULTS[key]
	for key in Figure.OPTIONS:
		var v = info.get(key, 0)
		out[key] = clampi(v, 0, Figure.OPTIONS[key].size() - 1) if v is int else 0
	return out


# ---------------- Connection events ----------------

func _on_connected() -> void:
	if not multiplayer.is_server():
		register.rpc_id(1, my_info)


func _on_relay_error(msg: String) -> void:
	if in_game:
		back_to_menu.call_deferred(msg)
	else:
		_drop_peer.call_deferred()
		if is_instance_valid(menu):
			menu.set_status(msg)


func _drop_peer() -> void:
	multiplayer.multiplayer_peer = null


func _on_connection_failed() -> void:
	_drop_peer.call_deferred()


func _on_server_disconnected() -> void:
	back_to_menu.call_deferred("The host left the game.")


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		if players.has(id):
			system_msg.rpc("%s left the game." % players[id]["name"])
		# the host takes over anything they were holding or driving
		for e in entities.values():
			if e.driver_id == id:
				set_driver.rpc(e.ent_id, 0)
			if e.owner_id == id:
				set_ent_owner.rpc(e.ent_id, 1)
		alive.erase(id)
		teams.erase(id)
		if is_dodgeball():
			_dodge_sync("")
	_remove_player(id)
	teams.erase(id)


# Client -> host: "here's who I am". Host sends back the whole world.
@rpc("any_peer", "reliable")
func register(info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	info = clean_info(info)
	players[id] = info
	var blist := []
	for bid in bricks:
		var b: Array = bricks[bid]
		blist.append([bid, b[0], b[1], b[2], b[3], b[4], doors_open.has(bid)])
	var elist := []
	for e in entities.values():
		elist.append([e.ent_id, e.type, e.position, e.quaternion, e.owner_id, e.driver_id, e.state])
	var extra := {
		"teams": teams, "limit": brick_limit, "state": dodge_state, "timer": dodge_timer,
		"score": score, "alive": alive.keys(), "wires": wires,
	}
	setup_world.rpc_id(id, map_id, plane_color, players, blist, elist, extra)
	for other in players:
		if other != 1 and other != id:
			add_player.rpc_id(other, id, info)
	_spawn_player(id, info)
	system_msg.rpc("%s joined the game!" % info["name"])
	brick_budget.rpc_id(id, _budget_left(id))


@rpc("authority", "reliable")
func setup_world(m: int, c: Color, plist: Dictionary, blist: Array, elist: Array, extra: Dictionary) -> void:
	map_id = m
	plane_color = c
	brick_limit = extra.get("limit", 0)
	teams = extra.get("teams", {})
	dodge_state = extra.get("state", "waiting")
	dodge_timer = extra.get("timer", 0.0)
	score = extra.get("score", score)
	alive.clear()
	for a in extra.get("alive", []):
		alive[a] = true
	wires = extra.get("wires", [])
	for b in blist:
		if b[6]:
			doors_open[b[0]] = true
		_add_brick(b[0], b[1], b[2], b[3], b[4], b[5])
	_start_world()
	for e in elist:
		_add_entity(e[0], e[1], e[2], e[3], e[4], e[5], e[6] if e.size() > 6 else {})
	for id in plist:
		_spawn_player(id, plist[id])
	if is_dodgeball():
		hud.add_system("Joined Dodgeball! Pick a team to play.")
	else:
		hud.add_system("Joined %s! B to spawn things, E for the funbrick tool, T to chat." % Maps.NAMES[map_id])


@rpc("authority", "reliable")
func add_player(id: int, info: Dictionary) -> void:
	if in_game:
		_spawn_player(id, info)


# ---------------- Players ----------------

func _spawn_player(id: int, info: Dictionary) -> void:
	players[id] = info
	if player_nodes.has(id):
		return
	var p: CharacterBody3D = PlayerScript.new()
	p.name = "P%d" % id
	p.peer_id = id
	p.info = info
	p.is_local = id == my_id()
	p.main = self
	var spawn := spawn_point_for(id)
	if p.is_local:
		spawn += Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	p.position = spawn
	p.target_pos = spawn
	player_root.add_child(p)
	player_nodes[id] = p
	p.set_team(teams.get(id, ""))


func _remove_player(id: int) -> void:
	if player_nodes.has(id):
		player_nodes[id].queue_free()
		player_nodes.erase(id)
	players.erase(id)


# Where a player should (re)appear: their team's side in dodgeball, or the bench if they're out.
func spawn_point_for(id: int) -> Vector3:
	if not is_dodgeball():
		return Maps.spawn_point(map_id)
	var team: String = teams.get(id, "")
	if team == "" or (dodge_state == "playing" and not alive.has(id)):
		return Maps.spawn_point(map_id)
	return Maps.spawn_point(map_id, team)


func send_transform(pos: Vector3, yaw: float, anim: int, vehicle: int) -> void:
	sync_tf.rpc(pos, yaw, anim, vehicle)


@rpc("any_peer", "unreliable_ordered")
func sync_tf(pos: Vector3, yaw: float, anim: int, vehicle: int) -> void:
	var p = player_nodes.get(multiplayer.get_remote_sender_id())
	if p:
		p.net_update(pos, yaw, anim, vehicle)


# ---------------- Physics props and vehicles ----------------

# ---------------- Explosives ----------------

# The owner saw it hit something hard (or it was wired / lit): tell the host to blow it up.
func report_explode(id: int) -> void:
	if multiplayer.is_server():
		_server_explode(id)
	else:
		req_explode.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_explode(id: int) -> void:
	if multiplayer.is_server():
		_server_explode(id)


func request_fuse(id: int) -> void:
	if multiplayer.is_server():
		_server_fuse(id)
	else:
		req_fuse.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_fuse(id: int) -> void:
	if multiplayer.is_server():
		_server_fuse(id)


func _server_fuse(id: int) -> void:
	var e = entities.get(id)
	if e and Entities.TYPES[e.type].get("explosive", false) and not fuses.has(id):
		fuses[id] = 3.0
		fuse_lit.rpc(id)


@rpc("authority", "call_local", "reliable")
func fuse_lit(id: int) -> void:
	var e = entities.get(id)
	if e:
		audio.play("fuse", e.global_position)
		var spark := OmniLight3D.new()
		spark.light_color = Color(1.0, 0.6, 0.2)
		spark.light_energy = 2.0
		spark.omni_range = 3.0
		spark.position = Vector3(0, 0.5, 0)
		e.add_child(spark)
		var tw := spark.create_tween().set_loops(15)
		tw.tween_property(spark, "light_energy", 0.3, 0.1)
		tw.tween_property(spark, "light_energy", 2.0, 0.1)


func _server_explode(id: int) -> void:
	var e = entities.get(id)
	if e == null:
		return
	var pos: Vector3 = e.global_position
	delete_ent.rpc(id)
	explode_at.rpc(pos)
	# blow away nearby bricks
	var box := AABB(pos - Vector3.ONE * EXPLOSION_RADIUS, Vector3.ONE * EXPLOSION_RADIUS * 2.0)
	var hit := {}
	for cell in _cells(box):
		for bid in brick_cells.get(cell, []):
			if (bricks[bid][0] as Vector3).distance_to(pos) < EXPLOSION_RADIUS:
				hit[bid] = true
	for bid in hit:
		remove_brick.rpc(bid)
	# chain reaction
	for other in entities.values():
		if Entities.TYPES[other.type].get("explosive", false) and other.global_position.distance_to(pos) < BLAST_RADIUS * 0.7 and not fuses.has(other.ent_id):
			fuses[other.ent_id] = 0.15 + randf() * 0.2


@rpc("authority", "call_local", "reliable")
func explode_at(pos: Vector3) -> void:
	audio.play("explosion", pos, 6.0)
	_explosion_fx(pos)
	# everyone shoves the things they're running
	for e in entities.values():
		if e.is_mine():
			var d: Vector3 = e.global_position - pos
			var dist := d.length()
			if dist < BLAST_RADIUS:
				var push := (1.0 - dist / BLAST_RADIUS)
				e.sleeping = false
				e.apply_central_impulse((d.normalized() + Vector3.UP * 0.6).normalized() * e.mass * 16.0 * push)
				e.angular_velocity += Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)) * push
	var p := local_player()
	if p and not p.vehicle:
		var d: Vector3 = p.global_position + Vector3.UP - pos
		if d.length() < BLAST_RADIUS:
			var push := 1.0 - d.length() / BLAST_RADIUS
			p.velocity += (d.normalized() + Vector3.UP * 0.8).normalized() * 18.0 * push


func _explosion_fx(pos: Vector3) -> void:
	var fx := Node3D.new()
	fx.position = pos
	add_child(fx)
	var ball := Figure.sphere(fx, 1.0, Vector3.ZERO, Color(1.0, 0.55, 0.1))
	var mat := Figure.glow_mat(Color(1.0, 0.55, 0.1)).duplicate() as StandardMaterial3D
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ball.material_override = mat
	ball.scale = Vector3.ONE * 0.5
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 8.0
	light.omni_range = 18.0
	fx.add_child(light)
	var debris := CPUParticles3D.new()
	debris.one_shot = true
	debris.amount = 40
	debris.lifetime = 1.2
	debris.explosiveness = 1.0
	debris.direction = Vector3.UP
	debris.spread = 180.0
	debris.initial_velocity_min = 6.0
	debris.initial_velocity_max = 14.0
	debris.gravity = Vector3(0, -18, 0)
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * 0.18
	debris.mesh = cube
	debris.material_override = Figure.mat(Color(0.25, 0.22, 0.2))
	debris.emitting = true
	fx.add_child(debris)
	var tw := fx.create_tween().set_parallel(true)
	tw.tween_property(ball, "scale", Vector3.ONE * 4.5, 0.35).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5).set_delay(0.15)
	tw.tween_property(light, "light_energy", 0.0, 0.6)
	tw.chain().tween_interval(0.8)
	tw.chain().tween_callback(fx.queue_free)


# ---------------- Tool gun ----------------

enum { TOOL_WELD, TOOL_FREEZE, TOOL_BALLOON, TOOL_THRUSTER, TOOL_WIRE, TOOL_REMOVER }
const TOOL_NAMES := ["Weld", "Freeze", "Balloon", "Thruster", "Wire", "Remover"]
const TOOL_HINTS := [
	"Click one thing, then another, to weld them together",
	"Click to pin something in place (click again to let go)",
	"Click to tie a balloon on · right click pops them",
	"Click to stick on a thruster (F turns them on/off) · right click removes them",
	"Click a button or pressure plate, then a door / lamp / thruster / TNT · right click cuts its wires",
	"Click anything to delete it",
]


@rpc("authority", "call_local", "reliable")
func set_ent_state(id: int, st: Dictionary) -> void:
	var e = entities.get(id)
	if e:
		e.apply_state(st)


func _push_state(e: Node) -> void:
	set_ent_state.rpc(e.ent_id, e.state.duplicate(true))


# point/normal are in the target's local space.
func request_tool(tool: int, id: int, point: Vector3, normal: Vector3, extra := 0, alt := false) -> void:
	if multiplayer.is_server():
		_server_tool(1, tool, id, point, normal, extra, alt)
	else:
		req_tool.rpc_id(1, tool, id, point, normal, extra, alt)


@rpc("any_peer", "reliable")
func req_tool(tool: int, id: int, point: Vector3, normal: Vector3, extra: int, alt: bool) -> void:
	if multiplayer.is_server():
		_server_tool(multiplayer.get_remote_sender_id(), tool, id, point, normal, extra, alt)


func _server_tool(_peer: int, tool: int, id: int, point: Vector3, normal: Vector3, extra: int, alt: bool) -> void:
	if is_dodgeball():
		return
	var e = entities.get(id)
	match tool:
		TOOL_WELD:
			var other = entities.get(extra)
			if e == null or other == null or e == other or Entities.is_vehicle(other.type) or other.driver_id != 0:
				return
			var list: Array = e.state.get("welded", []).duplicate()
			var rel: Transform3D = e.global_transform.affine_inverse() * other.global_transform
			list.append([other.type, rel])
			for part in other.state.get("welded", []):
				list.append([part[0], rel * (part[1] as Transform3D)])
			if list.size() > 24:
				return
			delete_ent.rpc(extra)
			e.state["welded"] = list
			_push_state(e)
		TOOL_FREEZE:
			if e and e.driver_id == 0:
				e.state["frozen"] = not e.state.get("frozen", false)
				_push_state(e)
		TOOL_BALLOON:
			if e == null:
				return
			var b: Array = e.state.get("balloons", []).duplicate()
			if alt:
				b.clear()
			elif b.size() < 12:
				b.append(point)
			e.state["balloons"] = b
			_push_state(e)
		TOOL_THRUSTER:
			if e == null:
				return
			var t: Array = e.state.get("thrusters", []).duplicate()
			if alt:
				t.clear()
			elif t.size() < 8:
				t.append([point, -normal.normalized()])
			e.state["thrusters"] = t
			_push_state(e)
		TOOL_REMOVER:
			if e and e.driver_id == 0:
				delete_ent.rpc(id)


func request_wire(src: int, kind: String, target: int, clear := false) -> void:
	if multiplayer.is_server():
		_server_wire(src, kind, target, clear)
	else:
		req_wire.rpc_id(1, src, kind, target, clear)


@rpc("any_peer", "reliable")
func req_wire(src: int, kind: String, target: int, clear: bool) -> void:
	if multiplayer.is_server():
		_server_wire(src, kind, target, clear)


func _server_wire(src: int, kind: String, target: int, clear: bool) -> void:
	var e = entities.get(src)
	if e == null or (e.type != Entities.BUTTON and e.type != Entities.PLATE):
		return
	var list := wires.duplicate()
	if clear:
		list = list.filter(func(w): return w[0] != src)
	else:
		if (kind == "ent" and not entities.has(target)) or (kind == "brick" and not bricks.has(target)):
			return
		if list.size() >= 300:
			return
		list.append([src, kind, target])
	wires_set.rpc(list)


@rpc("authority", "call_local", "reliable")
func wires_set(list: Array) -> void:
	wires = list
	audio.play("beep", null, -8.0)


# F on a button / lamp / thing with thrusters.
func request_press(id: int) -> void:
	if multiplayer.is_server():
		_server_press(id)
	else:
		req_press.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_press(id: int) -> void:
	if multiplayer.is_server():
		_server_press(id)


func _server_press(id: int) -> void:
	var e = entities.get(id)
	if e == null:
		return
	if e.type == Entities.BUTTON:
		pressed_fx.rpc(id)
		_trigger(id, true, true)
	elif e.type == Entities.LAMP or not e.state.get("thrusters", []).is_empty():
		e.state["on"] = not e.state.get("on", true)
		_push_state(e)


@rpc("authority", "call_local", "reliable")
func pressed_fx(id: int) -> void:
	var e = entities.get(id)
	if e:
		e.press_anim()
		audio.play("click", e.global_position)


# Sends a button press or plate change down its wires.
func _trigger(src: int, active: bool, toggle: bool) -> void:
	for w in wires:
		if w[0] != src:
			continue
		if w[1] == "brick":
			var bid: int = w[2]
			if not bricks.has(bid) or bricks[bid][3] != Bricks.DOOR:
				continue
			var want := not doors_open.has(bid) if toggle else active
			if want != doors_open.has(bid):
				set_door.rpc(bid, want)
		else:
			var t = entities.get(w[2])
			if t == null:
				continue
			if Entities.TYPES[t.type].get("explosive", false):
				if toggle or active:
					fuses[t.ent_id] = 0.05
			elif t.type == Entities.LAMP or not t.state.get("thrusters", []).is_empty():
				var want: bool = not t.state.get("on", true) if toggle else active
				if want != t.state.get("on", true):
					t.state["on"] = want
					_push_state(t)
			elif t.type == Entities.BUTTON:
				pressed_fx.rpc(t.ent_id)


# Host: a plate is pressed while a player or a prop rests on it.
func _check_plates() -> void:
	for e in entities.values():
		if e.type != Entities.PLATE:
			continue
		var area := AABB(e.global_position + Vector3(-0.8, 0.0, -0.8), Vector3(1.6, 1.6, 1.6))
		var pressed := false
		for p in player_nodes.values():
			if area.has_point(p.global_position + Vector3.UP * 0.2):
				pressed = true
				break
		if not pressed:
			for other in entities.values():
				if other != e and area.has_point(other.global_position):
					pressed = true
					break
		if pressed != e.state.get("pressed", false):
			e.state["pressed"] = pressed
			_push_state(e)
			if pressed:
				pressed_fx.rpc(e.ent_id)
			_trigger(e.ent_id, pressed, false)


func entity_respawn_point() -> Vector3:
	return Maps.spawn_point(map_id) + Vector3(randf_range(-3, 3), 3, randf_range(-3, 3))


func _on_spawn_chosen(type: int) -> void:
	var p := local_player()
	if p:
		var spot: Array = p.spawn_spot(type)
		request_spawn(type, spot[0], spot[1])


func request_spawn(type: int, pos: Vector3, yaw: float) -> void:
	if multiplayer.is_server():
		_server_spawn(1, type, pos, yaw)
	else:
		req_spawn.rpc_id(1, type, pos, yaw)


@rpc("any_peer", "reliable")
func req_spawn(type: int, pos: Vector3, yaw: float) -> void:
	if multiplayer.is_server():
		_server_spawn(multiplayer.get_remote_sender_id(), type, pos, yaw)


func _server_spawn(peer: int, type: int, pos: Vector3, yaw: float) -> void:
	if type < 0 or type >= Entities.TYPES.size() or is_dodgeball() or pos.length() > 1000.0:
		return
	if entities.size() >= MAX_ENTITIES:
		_notify(peer, "Too many things in the world (max %d). Delete some with X." % MAX_ENTITIES)
		return
	var mine := 0
	for id in ent_spawner:
		if ent_spawner[id] == peer:
			mine += 1
	if mine >= MAX_ENTITIES_PER_PLAYER:
		_notify(peer, "You've spawned the max of %d things. Delete some with X." % MAX_ENTITIES_PER_PLAYER)
		return
	var id := next_ent_id
	ent_spawner[id] = peer
	spawn_ent.rpc(id, type, pos, Quaternion(Vector3.UP, yaw), peer, 0)


@rpc("authority", "call_local", "reliable")
func spawn_ent(id: int, type: int, pos: Vector3, rot: Quaternion, owner_peer: int, driver: int) -> void:
	_add_entity(id, type, pos, rot, owner_peer, driver)


func _add_entity(id: int, type: int, pos: Vector3, rot: Quaternion, owner_peer: int, driver: int, st := {}) -> void:
	next_ent_id = maxi(next_ent_id, id + 1)
	if entities.has(id) or entity_root == null:
		return
	var e: RigidBody3D = EntityScript.new()
	e.name = "E%d" % id
	e.ent_id = id
	e.type = type
	e.owner_id = owner_peer
	e.driver_id = driver
	e.main = self
	e.position = pos
	e.quaternion = rot
	e.state = st
	entity_root.add_child(e)
	entities[id] = e


func request_delete(id: int) -> void:
	if multiplayer.is_server():
		_server_delete(id)
	else:
		req_delete.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_delete(id: int) -> void:
	if multiplayer.is_server() and not is_dodgeball():
		_server_delete(id)


func _server_delete(id: int) -> void:
	if entities.has(id):
		delete_ent.rpc(id)


@rpc("authority", "call_local", "reliable")
func delete_ent(id: int) -> void:
	ent_spawner.erase(id)
	fuses.erase(id)
	wires = wires.filter(func(w): return w[0] != id and not (w[1] == "ent" and w[2] == id))
	if entities.has(id):
		entities[id].queue_free()
		entities.erase(id)


# Ask the host to let us run this thing's physics (so we can grab or push it).
func request_own(id: int) -> void:
	if multiplayer.is_server():
		_server_own(1, id)
	else:
		req_own.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_own(id: int) -> void:
	if multiplayer.is_server():
		_server_own(multiplayer.get_remote_sender_id(), id)


func _server_own(peer: int, id: int) -> void:
	var e = entities.get(id)
	if e and e.state.get("frozen", false) and e.type != Entities.BUTTON and e.type != Entities.PLATE:
		e.state["frozen"] = false
		_push_state(e)
	if e and e.owner_id != peer and (e.driver_id == 0 or e.driver_id == peer):
		set_ent_owner.rpc(id, peer)


@rpc("authority", "call_local", "reliable")
func set_ent_owner(id: int, peer: int) -> void:
	var e = entities.get(id)
	if e:
		e.set_owner_id(peer)
		var p := local_player()
		if p:
			p.on_owner_changed(e)


func request_drive(id: int, enter: bool) -> void:
	if multiplayer.is_server():
		_server_drive(1, id, enter)
	else:
		req_drive.rpc_id(1, id, enter)


@rpc("any_peer", "reliable")
func req_drive(id: int, enter: bool) -> void:
	if multiplayer.is_server():
		_server_drive(multiplayer.get_remote_sender_id(), id, enter)


func _server_drive(peer: int, id: int, enter: bool) -> void:
	var e = entities.get(id)
	if e == null or not Entities.is_vehicle(e.type):
		return
	if enter and e.driver_id == 0:
		set_driver.rpc(id, peer)
	elif not enter and e.driver_id == peer:
		set_driver.rpc(id, 0)


@rpc("authority", "call_local", "reliable")
func set_driver(id: int, peer: int) -> void:
	var e = entities.get(id)
	if e == null:
		return
	e.driver_id = peer
	if peer != 0:
		e.set_owner_id(peer)
	if peer == my_id():
		var p := local_player()
		if p:
			p.enter_vehicle(e)


@rpc("any_peer", "unreliable_ordered")
func sync_ents(states: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	for s in states:
		var e = entities.get(s[0])
		if e and e.owner_id == sender:
			e.net_update(s[1], s[2], s[3])


# ---------------- Dodgeball ----------------

func _team_count(team: String) -> int:
	var n := 0
	for id in teams:
		if teams[id] == team and players.has(id):
			n += 1
	return n


func _alive_count(team: String) -> int:
	var n := 0
	for id in alive:
		if teams.get(id, "") == team:
			n += 1
	return n


func _dodge_tick() -> void:
	var both := _team_count("red") > 0 and _team_count("blue") > 0
	match dodge_state:
		"waiting":
			if both:
				_dodge_begin_round()
		"build":
			if not both:
				_dodge_set("waiting", 0.0, "Waiting for players on both teams...")
			elif dodge_timer <= 0.0:
				_dodge_set("playing", 0.0, "GO! Grab the balls!")
		"playing":
			if not both:
				_dodge_set("waiting", 0.0, "Waiting for players on both teams...")
				return
			var red := _alive_count("red")
			var blue := _alive_count("blue")
			if red == 0 or blue == 0:
				var winner := "blue" if red == 0 else "red"
				score[winner] += 1
				_dodge_set("roundover", ROUND_OVER_TIME, "%s WINS THE ROUND!" % winner.to_upper())
		"roundover":
			if dodge_timer <= 0.0:
				if both:
					_dodge_begin_round()
				else:
					_dodge_set("waiting", 0.0, "Waiting for players on both teams...")


func _dodge_begin_round() -> void:
	_clear_all_bricks()
	for id in entities.keys():
		delete_ent.rpc(id)
	for i in DODGE_BALLS:
		var z := -Maps.COURT_Z + 1.5 + i * (Maps.COURT_Z * 2 - 3.0) / (DODGE_BALLS - 1)
		var id := next_ent_id
		ent_spawner[id] = 1
		spawn_ent.rpc(id, Entities.DODGEBALL_TYPE, Vector3(0, 0.6, z), Quaternion.IDENTITY, 1, 0)
	alive.clear()
	for id in teams:
		if players.has(id):
			alive[id] = true
	_dodge_set("build", BUILD_TIME, "Build your defenses! %d bricks each (E)." % DODGE_BRICKS)


func _dodge_set(state: String, timer: float, msg: String) -> void:
	dodge_state = state
	dodge_timer = timer
	_dodge_sync(msg)


func _dodge_sync(msg: String) -> void:
	dodge_update.rpc(dodge_state, dodge_timer, score, alive.keys(), msg)


@rpc("authority", "call_local", "reliable")
func dodge_update(state: String, timer: float, new_score: Dictionary, alive_ids: Array, msg: String) -> void:
	var was := dodge_state
	var was_alive := alive.has(my_id())
	dodge_state = state
	dodge_timer = timer
	score = new_score
	alive.clear()
	for a in alive_ids:
		alive[a] = true
	if hud and msg != "":
		hud.big_message(msg)
		if state == "roundover":
			audio.play("win")
		elif state == "playing" and was != "playing":
			audio.play("beep", null, 0.0, 1.5)
	var p := local_player()
	if p == null:
		return
	if state == "build" and was != "build":
		p.respawn()
	elif state == "playing" and was_alive and not alive.has(my_id()):
		p.knocked_out()


func request_team(team: String) -> void:
	if multiplayer.is_server():
		_server_team(1, team)
	else:
		req_team.rpc_id(1, team)


@rpc("any_peer", "reliable")
func req_team(team: String) -> void:
	if multiplayer.is_server():
		_server_team(multiplayer.get_remote_sender_id(), team)


func _server_team(peer: int, team: String) -> void:
	if team != "red" and team != "blue" or not is_dodgeball():
		return
	team_set.rpc(peer, team)
	if dodge_state == "build" or dodge_state == "waiting":
		alive[peer] = true
	else:
		alive.erase(peer)
	_dodge_sync("")
	system_msg.rpc("%s joined the %s team." % [players[peer]["name"], team.to_upper()])


@rpc("authority", "call_local", "reliable")
func team_set(id: int, team: String) -> void:
	teams[id] = team
	var p = player_nodes.get(id)
	if p:
		p.set_team(team)
		if id == my_id():
			p.respawn()


func can_grab_balls() -> bool:
	if not is_dodgeball():
		return true
	return dodge_state == "playing" and alive.has(my_id())


func report_ball_hit(_ent_id: int, victim: int, team: String) -> void:
	if multiplayer.is_server():
		_server_hit(1, victim, team)
	else:
		req_hit.rpc_id(1, victim, team)


@rpc("any_peer", "reliable")
func req_hit(victim: int, team: String) -> void:
	if multiplayer.is_server():
		_server_hit(multiplayer.get_remote_sender_id(), victim, team)


func _server_hit(thrower: int, victim: int, team: String) -> void:
	if not is_dodgeball() or dodge_state != "playing":
		return
	if teams.get(thrower, "") != team or teams.get(victim, "") == team or not alive.has(victim) or not alive.has(thrower):
		return
	alive.erase(victim)
	_dodge_sync("")
	system_msg.rpc("%s got hit by %s!" % [players[victim]["name"], players[thrower]["name"]])


func report_brick_hit(brick_id: int) -> void:
	if multiplayer.is_server():
		_server_brick_hit(brick_id)
	else:
		req_brick_hit.rpc_id(1, brick_id)


@rpc("any_peer", "reliable")
func req_brick_hit(brick_id: int) -> void:
	if multiplayer.is_server():
		_server_brick_hit(brick_id)


func _server_brick_hit(brick_id: int) -> void:
	if not is_dodgeball() or not bricks.has(brick_id):
		return
	var hp: int = brick_hp.get(brick_id, 2) - 1
	if hp <= 0:
		brick_hp.erase(brick_id)
		remove_brick.rpc(brick_id)
	else:
		brick_hp[brick_id] = hp


# ---------------- Funbricks ----------------

func _cells(box: AABB) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var a := Vector3i((box.position / BRICK_CELL).floor())
	var b := Vector3i((box.end / BRICK_CELL).floor())
	for x in range(a.x, b.x + 1):
		for y in range(a.y, b.y + 1):
			for z in range(a.z, b.z + 1):
				out.append(Vector3i(x, y, z))
	return out


func overlaps_any(pos: Vector3, size: Vector3i, rot: int) -> bool:
	var a := Bricks.box_of(pos, size, rot)
	for cell in _cells(a):
		for id in brick_cells.get(cell, []):
			var b: Array = bricks[id]
			if a.intersects(Bricks.box_of(b[0], b[1], b[4])):
				return true
	return false


func limit_for_players() -> int:
	return DODGE_BRICKS if is_dodgeball() else brick_limit


func _budget_left(peer: int) -> int:
	var limit := limit_for_players()
	if limit <= 0:
		return -1
	return maxi(limit - int(brick_count.get(peer, 0)), 0)


@rpc("authority", "call_local", "reliable")
func brick_budget(left: int) -> void:
	if hud:
		hud.set_budget(left)


func _send_budget(peer: int) -> void:
	if limit_for_players() > 0 and players.has(peer):
		brick_budget.rpc_id(peer, _budget_left(peer))


func _notify(peer: int, text: String) -> void:
	if peer == 1:
		notify(text)
	else:
		notify.rpc_id(peer, text)


@rpc("authority", "reliable")
func notify(text: String) -> void:
	if hud:
		hud.add_system(text)


func request_place(pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if multiplayer.is_server():
		_server_place(1, pos, size, color, shape, rot)
	else:
		req_place.rpc_id(1, pos, size, color, shape, rot)


@rpc("any_peer", "reliable")
func req_place(pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if multiplayer.is_server():
		_server_place(multiplayer.get_remote_sender_id(), pos, size, color, shape, rot)


# Dodgeball: you can only build on your own half of the court, and only while you're still in.
func can_build_here(peer: int, pos: Vector3, size: Vector3i, rot: int) -> bool:
	if not is_dodgeball():
		return true
	var team: String = teams.get(peer, "")
	if team == "" or not alive.has(peer) or dodge_state == "roundover":
		return false
	var box := Bricks.box_of(pos, size, rot)
	if box.position.z < -Maps.COURT_Z or box.end.z > Maps.COURT_Z:
		return false
	if team == "red":
		return box.end.x <= 0.0 and box.position.x >= -Maps.COURT_X
	return box.position.x >= 0.0 and box.end.x <= Maps.COURT_X


func _server_place(peer: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if not Bricks.is_valid(shape, size, rot):
		return
	if pos.length() > 1000.0 or bricks.size() >= MAX_BRICKS or overlaps_any(pos, size, rot):
		return
	if not can_build_here(peer, pos, size, rot):
		return
	if _budget_left(peer) == 0:
		_notify(peer, "You're out of bricks!")
		return
	var id := next_brick_id
	next_brick_id += 1
	if not history.has(peer):
		history[peer] = []
	history[peer].append(id)
	if history[peer].size() > 200:
		history[peer].pop_front()
	brick_owner[id] = peer
	brick_count[peer] = int(brick_count.get(peer, 0)) + 1
	place_brick.rpc(id, pos, size, color, shape, rot)
	_send_budget(peer)


@rpc("authority", "call_local", "reliable")
func place_brick(id: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	_add_brick(id, pos, size, color, shape, rot)
	audio.play("place", pos, -4.0, randf_range(0.9, 1.1))


func request_remove(id: int) -> void:
	if multiplayer.is_server():
		_server_remove(1, id)
	else:
		req_remove.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_remove(id: int) -> void:
	if multiplayer.is_server():
		_server_remove(multiplayer.get_remote_sender_id(), id)


# Removing your own brick gives it back to your budget. In dodgeball you can only remove your own.
func _server_remove(peer: int, id: int) -> void:
	if not bricks.has(id):
		return
	var owner_peer: int = brick_owner.get(id, 0)
	if is_dodgeball() and owner_peer != peer:
		return
	if owner_peer == peer:
		brick_count[peer] = maxi(int(brick_count.get(peer, 0)) - 1, 0)
	remove_brick.rpc(id)
	_send_budget(peer)


@rpc("authority", "call_local", "reliable")
func remove_brick(id: int) -> void:
	if not bricks.has(id):
		return
	var b: Array = bricks[id]
	audio.play("remove", b[0], -4.0, randf_range(0.9, 1.1))
	for cell in _cells(Bricks.box_of(b[0], b[1], b[4])):
		if brick_cells.has(cell):
			brick_cells[cell].erase(id)
			if brick_cells[cell].is_empty():
				brick_cells.erase(cell)
	var key := _chunk_of(b[0])
	if chunk_ids.has(key):
		chunk_ids[key].erase(id)
		dirty_chunks[key] = true
	bricks.erase(id)
	doors_open.erase(id)
	brick_owner.erase(id)
	if brick_nodes.has(id):
		brick_nodes[id].queue_free()
		brick_nodes.erase(id)


func request_undo() -> void:
	if multiplayer.is_server():
		_server_undo(1)
	else:
		req_undo.rpc_id(1)


@rpc("any_peer", "reliable")
func req_undo() -> void:
	if multiplayer.is_server():
		_server_undo(multiplayer.get_remote_sender_id())


func _server_undo(peer: int) -> void:
	var list: Array = history.get(peer, [])
	while list.size() > 0:
		var id: int = list.pop_back()
		if bricks.has(id):
			_server_remove(peer, id)
			return


func request_paint(id: int, color: Color) -> void:
	if multiplayer.is_server():
		_server_paint(id, color)
	else:
		req_paint.rpc_id(1, id, color)


@rpc("any_peer", "reliable")
func req_paint(id: int, color: Color) -> void:
	if multiplayer.is_server():
		_server_paint(id, color)


func _server_paint(id: int, color: Color) -> void:
	if bricks.has(id) and bricks[id][2] != color:
		paint_brick.rpc(id, color)


@rpc("authority", "call_local", "reliable")
func paint_brick(id: int, color: Color) -> void:
	if not bricks.has(id):
		return
	bricks[id][2] = color
	audio.play("paint", bricks[id][0], -6.0)
	if brick_nodes.has(id):
		brick_nodes[id].queue_free()
		brick_nodes.erase(id)
		_make_brick_node(id)


func request_door(id: int) -> void:
	if multiplayer.is_server():
		_server_door(id)
	else:
		req_door.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_door(id: int) -> void:
	if multiplayer.is_server():
		_server_door(id)


func _server_door(id: int) -> void:
	if bricks.has(id) and bricks[id][3] == Bricks.DOOR:
		set_door.rpc(id, not doors_open.has(id))


@rpc("authority", "call_local", "reliable")
func set_door(id: int, open: bool) -> void:
	if open:
		doors_open[id] = true
	else:
		doors_open.erase(id)
	if brick_nodes.has(id):
		Bricks.set_door_open(brick_nodes[id], open)
		audio.play("door", bricks[id][0])


func _clear_all_bricks() -> void:
	brick_count.clear()
	brick_hp.clear()
	clear_bricks.rpc()
	for peer in players:
		_send_budget(peer)


@rpc("authority", "call_local", "reliable")
func clear_bricks() -> void:
	for id in brick_nodes:
		brick_nodes[id].queue_free()
	for key in chunk_meshes:
		chunk_meshes[key].queue_free()
	bricks.clear()
	brick_nodes.clear()
	brick_cells.clear()
	chunk_ids.clear()
	chunk_meshes.clear()
	dirty_chunks.clear()
	doors_open.clear()
	history.clear()
	brick_owner.clear()


func _add_brick(id: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if bricks.has(id):
		return
	bricks[id] = [pos, size, color, shape, rot]
	next_brick_id = maxi(next_brick_id, id + 1)
	for cell in _cells(Bricks.box_of(pos, size, rot)):
		if not brick_cells.has(cell):
			brick_cells[cell] = []
		brick_cells[cell].append(id)
	if brick_root:
		_make_brick_node(id)


func _chunk_of(pos: Vector3) -> Vector3i:
	return Vector3i((pos / CHUNK).floor())


# Each brick keeps its collision, but its plain parts get drawn as part of one merged mesh per chunk.
func _make_brick_node(id: int) -> void:
	if brick_nodes.has(id):
		return
	var b: Array = bricks[id]
	var node := Bricks.make(b[3], b[1], b[2], false, doors_open.has(id))
	node.position = b[0]
	node.rotation.y = b[4] * PI * 0.5
	node.set_meta("brick_id", id)
	var panel := node.get_node_or_null("Hinge/Panel")
	if panel:
		panel.set_meta("brick_id", id)
	brick_root.add_child(node)
	brick_nodes[id] = node
	if b[3] != Bricks.DOOR:
		for c in node.get_children():
			if c is MeshInstance3D and Batcher.can_merge(c):
				c.visible = false
		var key := _chunk_of(b[0])
		if not chunk_ids.has(key):
			chunk_ids[key] = []
		if not chunk_ids[key].has(id):
			chunk_ids[key].append(id)
		dirty_chunks[key] = true


func _rebuild_chunk(key: Vector3i) -> void:
	var group := Batcher.Group.new()
	for id in chunk_ids.get(key, []):
		var node: Node3D = brick_nodes.get(id)
		if node == null:
			continue
		for c in node.get_children():
			if c is MeshInstance3D and not c.visible:
				var mi := c as MeshInstance3D
				group.add(mi.mesh, node.transform * mi.transform, (mi.material_override as StandardMaterial3D).albedo_color)
	if chunk_meshes.has(key):
		chunk_meshes[key].queue_free()
		chunk_meshes.erase(key)
	if group.verts.is_empty():
		chunk_ids.erase(key)
		return
	var mi := MeshInstance3D.new()
	mi.mesh = group.to_mesh(Batcher.material())
	chunk_root.add_child(mi)
	chunk_meshes[key] = mi


# ---------------- Saving builds (host only) ----------------

func _on_save_pressed(build_name: String) -> void:
	var safe := ""
	for ch in build_name.strip_edges():
		if ch.is_valid_identifier() or ch in "0123456789 -":
			safe += ch
	safe = safe.strip_edges().left(40)
	if safe == "":
		hud.set_pause_status("Type a name for your build first.")
		return
	var err := save_build(safe)
	hud.set_pause_status("Saved \"%s\" (%d bricks, %d things)!" % [safe, bricks.size(), entities.size()] if err == OK else "Couldn't save (error %d)." % err)


func save_build(build_name: String) -> int:
	var list := []
	for id in bricks:
		var b: Array = bricks[id]
		var p: Vector3 = b[0]
		var s: Vector3i = b[1]
		list.append([p.x, p.y, p.z, s.x, s.y, s.z, (b[2] as Color).to_html(false), b[3], b[4], doors_open.has(id)])
	var ents := []
	for e in entities.values():
		var p: Vector3 = e.position
		var q: Quaternion = e.quaternion
		ents.append([e.type, p.x, p.y, p.z, q.x, q.y, q.z, q.w, var_to_str(e.state)])
	# wires refer to things by their position in the lists above
	var ent_index := {}
	var i := 0
	for e in entities.values():
		ent_index[e.ent_id] = i
		i += 1
	var brick_index := {}
	i = 0
	for id in bricks:
		brick_index[id] = i
		i += 1
	var wire_list := []
	for w in wires:
		if not ent_index.has(w[0]):
			continue
		if w[1] == "ent" and ent_index.has(w[2]):
			wire_list.append([ent_index[w[0]], "ent", ent_index[w[2]]])
		elif w[1] == "brick" and brick_index.has(w[2]):
			wire_list.append([ent_index[w[0]], "brick", brick_index[w[2]]])
	var data := {"version": 3, "map": map_id, "ground": plane_color.to_html(false), "bricks": list, "ents": ents, "wires": wire_list}
	DirAccess.make_dir_recursive_absolute(BUILDS_DIR)
	var f := FileAccess.open("%s/%s.json" % [BUILDS_DIR, build_name], FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data))
	return OK


# Loads a saved build into the (not yet started) world. Returns how many bricks were loaded, or -1.
func _load_build(build_name: String) -> int:
	var f := FileAccess.open("%s/%s.json" % [BUILDS_DIR, build_name], FileAccess.READ)
	if f == null:
		return -1
	var data = JSON.parse_string(f.get_as_text())
	if not data is Dictionary:
		return -1
	map_id = clampi(int(data.get("map", map_id)), 0, Maps.NAMES.size() - 1)
	plane_color = Color.from_string(str(data.get("ground", "")), plane_color)
	var count := 0
	var brick_ids := []
	for b in data.get("bricks", []):
		if not b is Array or b.size() < 10:
			continue
		var size := Vector3i(int(b[3]), int(b[4]), int(b[5]))
		var shape := int(b[7])
		var rot := int(b[8])
		if not Bricks.is_valid(shape, size, rot):
			continue
		var id := next_brick_id
		if b[9]:
			doors_open[id] = true
		brick_owner[id] = 1
		_add_brick(id, Vector3(b[0], b[1], b[2]), size, Color.from_string(str(b[6]), Color.WHITE), shape, rot)
		brick_ids.append(id)
		count += 1
	pending_ents.clear()
	for e in data.get("ents", []):
		if e is Array and e.size() >= 8 and int(e[0]) >= 0 and int(e[0]) < Entities.TYPES.size():
			var st = str_to_var(e[8]) if e.size() > 8 else {}
			pending_ents.append([int(e[0]), Vector3(e[1], e[2], e[3]), Quaternion(e[4], e[5], e[6], e[7]).normalized(), st if st is Dictionary else {}])
	pending_wires = []
	for w in data.get("wires", []):
		if w is Array and w.size() == 3:
			pending_wires.append([int(w[0]), str(w[1]), int(w[2]), brick_ids])
	return count


# ---------------- Chat ----------------

func send_chat(text: String) -> void:
	if multiplayer.is_server():
		_server_chat(1, text)
	else:
		req_chat.rpc_id(1, text)


@rpc("any_peer", "reliable")
func req_chat(text: String) -> void:
	if multiplayer.is_server():
		_server_chat(multiplayer.get_remote_sender_id(), text)


func _server_chat(id: int, text: String) -> void:
	text = text.strip_edges().left(200)
	if text == "" or not players.has(id):
		return
	chat_msg.rpc(players[id]["name"], text, players[id]["shirt"])


@rpc("authority", "call_local", "reliable")
func chat_msg(who: String, text: String, color: Color) -> void:
	if hud:
		hud.add_chat(who, text, color)


@rpc("authority", "call_local", "reliable")
func system_msg(text: String) -> void:
	if hud:
		hud.add_system(text)


# ---------------- Test hooks (command line: godot -- autohost=2 autoquit=5) ----------------

func _handle_test_args() -> void:
	test_mode = not OS.get_cmdline_user_args().is_empty()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("autohost="):
			host_game({"name": "Host"}, int(a.get_slice("=", 1)), Color(0.3, 0.6, 0.9))
		elif a.begins_with("autoload="):
			host_game({"name": "Host"}, 0, Color(0.3, 0.6, 0.9), a.get_slice("=", 1))
		elif a == "autojoin":
			auto_join = true
			fetch_rooms()
		elif a == "autobrick":
			get_tree().create_timer(2.0).timeout.connect(func():
				for s in Bricks.SHAPES.size():
					request_place(Vector3(0.2 + s * 2.0, Bricks.SHAPES[s]["h"] * Bricks.PLATE * 0.5, 6.2), Bricks.size_for(s, 0), Color.RED, s, s % 4)
				send_chat("hello from %s" % my_info.get("name", "?")))
		elif a == "autoedit":
			get_tree().create_timer(3.5).timeout.connect(func():
				for id in bricks:
					if bricks[id][3] == Bricks.DOOR:
						request_door(id)
				request_paint(bricks.keys()[0], Color.BLUE)
				request_undo())
		elif a == "autospawn":
			get_tree().create_timer(2.0).timeout.connect(func():
				for t in Entities.TYPES.size():
					request_spawn(t, Vector3(-30 + (t % 7) * 8.0, 2.0, -15.0 - (t / 7) * 10.0), 0.0))
		elif a == "autopadmode":
			using_pad = true
		elif a.begins_with("autodrive="):
			# drive the vehicle of this type forward for a few seconds (W held)
			var vt := int(a.get_slice("=", 1))
			get_tree().create_timer(4.0).timeout.connect(func():
				for e in entities.values():
					if e.type == vt:
						request_drive(e.ent_id, true)
						print("TEST start ", Entities.TYPES[vt]["name"], " at ", e.position)
						Input.action_press("ui_up")
						var ev := InputEventKey.new()
						ev.physical_keycode = KEY_W
						ev.pressed = true
						if vt != 18:
							Input.parse_input_event(ev)
						if vt == 17:
							var sp := InputEventKey.new()
							sp.physical_keycode = KEY_SPACE
							sp.pressed = true
							Input.parse_input_event(sp)
						if vt == 18:
							var sh := InputEventKey.new()
							sh.physical_keycode = KEY_SHIFT
							sh.pressed = true
							Input.parse_input_event(sh)
						get_tree().create_timer(5.0).timeout.connect(func():
							print("TEST after 5s ", Entities.TYPES[vt]["name"], " at ", e.position, " speed ", e.linear_velocity.length(), " up ", e.global_basis.y))
						break)
		elif a == "autograb":
			get_tree().create_timer(5.0).timeout.connect(func():
				var e = entities.get(1)
				print("TEST grab ", e.ent_id, " owner before=", e.owner_id)
				request_own(1)
				await get_tree().create_timer(1.0).timeout
				print("TEST owner after=", e.owner_id, " mine=", e.is_mine())
				e.linear_velocity = Vector3(0, 12, 0)
				await get_tree().create_timer(0.5).timeout
				print("TEST joiner sees y=", e.position.y))
		elif a == "autohit":
			get_tree().create_timer(17.0).timeout.connect(func():
				print("TEST client state before hit: ", dodge_state, " alive=", alive.keys(), " balls=", entities.size(), " budget=", hud.budget)
				request_place(Vector3(10.2, 0.24 + 0.06, 3.2), Vector3i(2, 3, 4), Color.BLUE, 0, 0)
				report_ball_hit(0, 1, "blue"))
		elif a == "autopad":
			get_tree().create_timer(3.0).timeout.connect(func():
				var p := local_player()
				var start: Vector3 = p.position
				var m := InputEventJoypadMotion.new()
				m.axis = JOY_AXIS_LEFT_Y
				m.axis_value = -1.0
				Input.parse_input_event(m)
				await get_tree().create_timer(1.5).timeout
				print("TEST pad walk moved ", snappedf(p.position.distance_to(start), 0.1), " m, using_pad=", using_pad)
				m.axis_value = 0.0
				Input.parse_input_event(m)
				for e in entities.values():
					if e.type == 13:
						request_drive(e.ent_id, true)
						var car_start: Vector3 = e.position
						var rt := InputEventJoypadMotion.new()
						rt.axis = JOY_AXIS_TRIGGER_RIGHT
						rt.axis_value = 1.0
						Input.parse_input_event(rt)
						await get_tree().create_timer(2.0).timeout
						print("TEST pad car moved ", snappedf(e.position.distance_to(car_start), 0.1), " m, driving=", p.vehicle != null)
						break)
		elif a == "autoboom":
			get_tree().create_timer(4.0).timeout.connect(func():
				for e in entities.values():
					if e.type == 19:
						print("TEST lighting TNT, ents=", entities.size())
						request_fuse(e.ent_id)
						break
				await get_tree().create_timer(4.0).timeout
				print("TEST after boom ents=", entities.size()))
		elif a == "autoswim":
			get_tree().create_timer(3.0).timeout.connect(func():
				var p := local_player()
				p.position = Vector3(16, 1.0, -14)
				await get_tree().create_timer(2.5).timeout
				print("TEST swimming=", p.swimming, " y=", snappedf(p.position.y, 0.01), " water top=", water_top(p.position + Vector3.UP * 1.1)))
		elif a == "autoboat":
			get_tree().create_timer(2.5).timeout.connect(func():
				using_pad = true
				request_spawn(21, Vector3(0, 0.5, 130), PI)
				await get_tree().create_timer(2.0).timeout
				for e in entities.values():
					if e.type == 21:
						print("TEST boat floating at y=", snappedf(e.position.y, 0.01))
						request_drive(e.ent_id, true)
						var ev := InputEventKey.new()
						ev.physical_keycode = KEY_W
						ev.pressed = true
						Input.parse_input_event(ev)
						var start: Vector3 = e.position
						await get_tree().create_timer(4.0).timeout
						print("TEST boat moved ", snappedf(e.position.distance_to(start), 0.1), " y=", snappedf(e.position.y, 0.01), " up=", e.global_basis.y.snapped(Vector3.ONE * 0.01)))
		elif a == "autoballoon":
			get_tree().create_timer(2.5).timeout.connect(func():
				request_spawn(0, Vector3(0, 0.6, -6), 0.0)
				request_spawn(0, Vector3(1.0, 0.6, -6), 0.0)
				await get_tree().create_timer(1.5).timeout
				var e = entities.values()[0]
				print("TEST before weld y=", e.position.y)
				request_tool(TOOL_WELD, e.ent_id, Vector3.ZERO, Vector3.ZERO, entities.values()[1].ent_id)
				await get_tree().create_timer(0.3).timeout
				for i in 3:
					request_tool(TOOL_BALLOON, e.ent_id, Vector3(0, 0.5, 0), Vector3.UP)
				for i in 3:
					request_tool(TOOL_BALLOON, e.ent_id, Vector3(0, 0.5, 0), Vector3.UP)
				for k in 6:
					await get_tree().create_timer(0.3).timeout
					print("TEST bal y=", snappedf(e.position.y, 0.01), " v=", e.linear_velocity.snapped(Vector3.ONE * 0.01), " sleep=", e.sleeping, " freeze=", e.freeze, " mass=", e.mass))
		elif a == "autotools":
			get_tree().create_timer(2.5).timeout.connect(func():
				var wait := func(t): await get_tree().create_timer(t).timeout
				request_spawn(0, Vector3(0, 0.6, -6), 0.0)      # crate A
				request_spawn(0, Vector3(1.0, 0.6, -6), 0.0)    # crate B, touching A
				request_spawn(Entities.BUTTON, Vector3(-4, 0.65, -6), 0.0)
				request_spawn(Entities.LAMP, Vector3(5, 1.2, -6), 0.0)
				request_spawn(Entities.PLATE, Vector3(12, 0.05, -6), 0.0)
				request_spawn(19, Vector3(16, 0.4, -6), 0.0)    # TNT
				request_spawn(1, Vector3(-8, 0.4, -6), 0.0)     # small crate for a thruster
				request_place(Vector3(0.2, 15 * Bricks.PLATE * 0.5, -14.2), Bricks.size_for(Bricks.DOOR, 0), Color.WHITE, Bricks.DOOR, 0)
				await wait.call(2.0)
				var ids := entities.keys()
				var a_id: int = ids[0]
				var b_id: int = ids[1]
				var button: int = ids[2]
				var lamp: int = ids[3]
				var plate: int = ids[4]
				var tnt: int = ids[5]
				var small: int = ids[6]
				var door: int = bricks.keys()[0]
				print("TEST A at ", entities[a_id].position, " B at ", entities[b_id].position)
				request_tool(TOOL_WELD, a_id, Vector3.ZERO, Vector3.ZERO, b_id)
				await wait.call(0.3)
				print("TEST weld: B gone=", not entities.has(b_id), " A parts=", entities[a_id].state.get("welded", []).size(), " A mass=", entities[a_id].mass)
				for i in 3:
					request_tool(TOOL_BALLOON, a_id, Vector3(0, 0.5, 0), Vector3.UP)
				var small_y: float = entities[small].position.y
				request_tool(TOOL_THRUSTER, small, Vector3(0, -0.3, 0), Vector3.DOWN)
				request_wire(button, "ent", lamp)
				request_wire(button, "brick", door)
				request_wire(plate, "ent", tnt)
				await wait.call(2.0)
				print("TEST A v=", entities[a_id].linear_velocity, " sleep=", entities[a_id].sleeping, " freeze=", entities[a_id].freeze, " colliders=", entities[a_id].get_children().filter(func(c): return c is CollisionShape3D).size())
				print("TEST balloons lifted A to y=", snappedf(entities[a_id].position.y, 0.1), " thruster crate y ", snappedf(small_y, 0.1), " -> ", snappedf(entities[small].position.y, 0.1) if entities.has(small) else "gone")
				print("TEST wires=", wires.size(), " lamp on=", entities[lamp].state.get("on"), " door open=", doors_open.has(door))
				request_press(button)
				await wait.call(0.5)
				print("TEST after button: lamp on=", entities[lamp].state.get("on"), " door open=", doors_open.has(door))
				request_spawn(1, Vector3(12, 1.5, -6), 0.0)    # drop a crate on the plate
				await wait.call(1.5)
				print("TEST plate pressed=", entities[plate].state.get("pressed"), " TNT still there=", entities.has(tnt), " fuses=", fuses)
				var ea = entities[a_id]
				print("TEST A freeze=", ea.freeze, " sleeping=", ea.sleeping, " mine=", ea.is_mine(), " state=", ea.state.keys(), " balloons=", ea.state.get("balloons"), " gs=", ea.gravity_scale, " paused=", get_tree().paused))
		elif a == "autoteam":
			get_tree().create_timer(2.5).timeout.connect(func(): request_team("red" if multiplayer.is_server() else "blue"))
		elif a.begins_with("autosave="):
			get_tree().create_timer(5.0).timeout.connect(func(): print("TEST save=", save_build(a.get_slice("=", 1))))
		elif a.begins_with("autoquit="):
			get_tree().create_timer(float(a.get_slice("=", 1))).timeout.connect(func():
				print("TEST players=", players.keys(), " nodes=", player_nodes.size(), " bricks=", bricks.size(), " doors_open=", doors_open.keys(), " ents=", entities.size(), " chunks=", chunk_meshes.size())
				if is_dodgeball():
					print("TEST dodge state=", dodge_state, " teams=", teams, " alive=", alive.keys(), " score=", score)
				var sleeping := 0
				for e in entities.values():
					if e.sleeping:
						sleeping += 1
				print("TEST ents sleeping=", sleeping)
				if entities.has(1):
					print("TEST ent1 owner=", entities[1].owner_id, " y=", entities[1].position.y)
				for e in entities.values():
					if Entities.is_vehicle(e.type):
						print("TEST rest ", Entities.TYPES[e.type]["name"], " y=", snappedf(e.position.y, 0.01), " up=", e.global_basis.y.snapped(Vector3.ONE * 0.01))
				if world:
					print("TEST map meshes drawn=", world.find_children("*", "MeshInstance3D", true, false).size())
				if hud:
					print("TEST chat: ", hud.log_label.get_parsed_text().replace("\n", " | "))
				get_tree().quit())
