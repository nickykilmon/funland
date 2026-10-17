extends Node3D
# FunLand main: menu, networking (host + join), shared world state (players, funbricks), chat and saving.
# The host is the boss: clients ask it to place/remove/paint bricks or chat, and it tells everyone.

const ONLINE_URL := "wss://funland.onrender.com/ws"
const MAX_BRICKS := 20000
const BUILDS_DIR := "user://builds"

const Maps = preload("res://scripts/maps.gd")
const Bricks = preload("res://scripts/bricks.gd")
const Figure = preload("res://scripts/figure.gd")
const PlayerScript = preload("res://scripts/player.gd")
const MenuScript = preload("res://scripts/menu.gd")
const HudScript = preload("res://scripts/hud.gd")
const RelayPeer = preload("res://scripts/relay_peer.gd")

var menu: CanvasLayer
var hud: CanvasLayer
var world: Node3D
var brick_root: Node3D
var player_root: Node3D
var in_game := false

var my_info := {}
var players := {}       # peer id -> info dictionary
var player_nodes := {}  # peer id -> player node
var bricks := {}        # brick id -> [pos, size, color, shape, rot]
var brick_nodes := {}   # brick id -> brick node
var doors_open := {}    # brick id -> true for open doors
var history := {}       # peer id -> brick ids they placed (host only, for undo)
var next_brick_id := 1
var map_id := 0
var plane_color := Color(0.3, 0.68, 0.25)
var room_code := ""
var loaded_build := ""
var list_ws: WebSocketPeer
var list_sent := false
var auto_join := false


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu = MenuScript.new()
	add_child(menu)
	menu.host_requested.connect(host_game)
	menu.join_requested.connect(join_game)
	_handle_test_args()


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


func host_game(info: Dictionary, map: int, color: Color, build_name := "") -> void:
	my_info = clean_info(info)
	map_id = clampi(map, 0, Maps.NAMES.size() - 1)
	plane_color = color
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
	_spawn_player(1, my_info)
	hud.is_host = true
	hud.set_room(code)
	hud.add_system("Your room code is %s. Friends find it in the room list on the start screen." % code)
	if loaded_build != "":
		hud.add_system(loaded_build)


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


func _process(_delta: float) -> void:
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
	brick_root = Node3D.new()
	brick_root.name = "Bricks"
	add_child(brick_root)
	player_root = Node3D.new()
	player_root.name = "Players"
	add_child(player_root)
	hud = HudScript.new()
	add_child(hud)
	hud.chat_sent.connect(send_chat)
	hud.leave_pressed.connect(back_to_menu)
	hud.save_pressed.connect(_on_save_pressed)
	hud.clear_pressed.connect(func():
		if multiplayer.is_server():
			clear_bricks.rpc()
			system_msg.rpc("The host cleared all the bricks."))
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
	if multiplayer.is_server() and players.has(id):
		system_msg.rpc("%s left the game." % players[id]["name"])
	_remove_player(id)


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
	setup_world.rpc_id(id, map_id, plane_color, players, blist)
	for other in players:
		if other != 1 and other != id:
			add_player.rpc_id(other, id, info)
	_spawn_player(id, info)
	system_msg.rpc("%s joined the game!" % info["name"])


@rpc("authority", "reliable")
func setup_world(m: int, c: Color, plist: Dictionary, blist: Array) -> void:
	map_id = m
	plane_color = c
	for b in blist:
		if b[6]:
			doors_open[b[0]] = true
		_add_brick(b[0], b[1], b[2], b[3], b[4], b[5])
	_start_world()
	for id in plist:
		_spawn_player(id, plist[id])
	hud.add_system("Joined %s! Press E for the funbrick tool, T to chat." % Maps.NAMES[map_id])


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
	p.is_local = id == multiplayer.get_unique_id()
	p.main = self
	var spawn := Maps.spawn_point(map_id)
	if p.is_local:
		spawn += Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
	p.position = spawn
	p.target_pos = spawn
	player_root.add_child(p)
	player_nodes[id] = p


func _remove_player(id: int) -> void:
	if player_nodes.has(id):
		player_nodes[id].queue_free()
		player_nodes.erase(id)
	players.erase(id)


func send_transform(pos: Vector3, yaw: float, anim: int) -> void:
	sync_tf.rpc(pos, yaw, anim)


@rpc("any_peer", "unreliable_ordered")
func sync_tf(pos: Vector3, yaw: float, anim: int) -> void:
	var p = player_nodes.get(multiplayer.get_remote_sender_id())
	if p:
		p.net_update(pos, yaw, anim)


# ---------------- Funbricks ----------------

func overlaps_any(pos: Vector3, size: Vector3i, rot: int) -> bool:
	var a := Bricks.box_of(pos, size, rot)
	for b in bricks.values():
		if a.intersects(Bricks.box_of(b[0], b[1], b[4])):
			return true
	return false


func request_place(pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if multiplayer.is_server():
		_server_place(1, pos, size, color, shape, rot)
	else:
		req_place.rpc_id(1, pos, size, color, shape, rot)


@rpc("any_peer", "reliable")
func req_place(pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if multiplayer.is_server():
		_server_place(multiplayer.get_remote_sender_id(), pos, size, color, shape, rot)


func _server_place(peer: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if not Bricks.is_valid(shape, size, rot):
		return
	if pos.length() > 1000.0 or bricks.size() >= MAX_BRICKS or overlaps_any(pos, size, rot):
		return
	var id := next_brick_id
	next_brick_id += 1
	if not history.has(peer):
		history[peer] = []
	history[peer].append(id)
	if history[peer].size() > 200:
		history[peer].pop_front()
	place_brick.rpc(id, pos, size, color, shape, rot)


@rpc("authority", "call_local", "reliable")
func place_brick(id: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	_add_brick(id, pos, size, color, shape, rot)


func request_remove(id: int) -> void:
	if multiplayer.is_server():
		_server_remove(id)
	else:
		req_remove.rpc_id(1, id)


@rpc("any_peer", "reliable")
func req_remove(id: int) -> void:
	if multiplayer.is_server():
		_server_remove(id)


func _server_remove(id: int) -> void:
	if bricks.has(id):
		remove_brick.rpc(id)


@rpc("authority", "call_local", "reliable")
func remove_brick(id: int) -> void:
	bricks.erase(id)
	doors_open.erase(id)
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
			remove_brick.rpc(id)
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


@rpc("authority", "call_local", "reliable")
func clear_bricks() -> void:
	for id in brick_nodes:
		brick_nodes[id].queue_free()
	bricks.clear()
	brick_nodes.clear()
	doors_open.clear()
	history.clear()


func _add_brick(id: int, pos: Vector3, size: Vector3i, color: Color, shape: int, rot: int) -> void:
	if bricks.has(id):
		return
	bricks[id] = [pos, size, color, shape, rot]
	next_brick_id = maxi(next_brick_id, id + 1)
	if brick_root:
		_make_brick_node(id)


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
	hud.set_pause_status("Saved \"%s\" (%d bricks)!" % [safe, bricks.size()] if err == OK else "Couldn't save (error %d)." % err)


func save_build(build_name: String) -> int:
	var list := []
	for id in bricks:
		var b: Array = bricks[id]
		var p: Vector3 = b[0]
		var s: Vector3i = b[1]
		list.append([p.x, p.y, p.z, s.x, s.y, s.z, (b[2] as Color).to_html(false), b[3], b[4], doors_open.has(id)])
	var data := {"version": 1, "map": map_id, "ground": plane_color.to_html(false), "bricks": list}
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
		_add_brick(id, Vector3(b[0], b[1], b[2]), size, Color.from_string(str(b[6]), Color.WHITE), shape, rot)
		count += 1
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
		elif a.begins_with("autosave="):
			get_tree().create_timer(5.0).timeout.connect(func(): print("TEST save=", save_build(a.get_slice("=", 1))))
		elif a.begins_with("autoquit="):
			get_tree().create_timer(float(a.get_slice("=", 1))).timeout.connect(func():
				print("TEST players=", players.keys(), " nodes=", player_nodes.size(), " bricks=", bricks.size(), " doors_open=", doors_open.keys())
				for id in bricks:
					print("TEST brick ", id, " shape=", bricks[id][3], " color=", bricks[id][2].to_html(false))
				if hud:
					print("TEST chat: ", hud.log_label.get_parsed_text().replace("\n", " | "))
				get_tree().quit())
