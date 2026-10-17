extends Node
# Game modes the host can pick on the start screen: Prop Hunt, Race, Build Battle and Capture the Flag.
# The host runs the rules and sends everyone the current phase, timer and data; each player's
# game reads that to show markers, lock movement, etc.

const Entities = preload("res://scripts/entities.gd")
const Figure = preload("res://scripts/figure.gd")
const Bricks = preload("res://scripts/bricks.gd")
const Maps = preload("res://scripts/maps.gd")

const NAMES := ["Sandbox", "Prop Hunt", "Race", "Build Battle", "Capture the Flag"]
enum { SANDBOX, PROP_HUNT, RACE, BUILD, CTF }

const HIDE_TIME := 30.0
const SEEK_TIME := 180.0
const RACE_LIMIT := 240.0
const BUILD_TIME := 180.0
const VOTE_TIME := 12.0
const OVER_TIME := 8.0
const PLOT := 20.0          # build battle plot size (m)
const CTF_BASE := 60.0      # bases this far either side of spawn
const CTF_WIN := 3
const KART := 15
const PROP_TYPES := [0, 1, 2, 3, 5, 6, 7, 9, 10, 11, 12]
const THEMES := ["Castle", "Spaceship", "Animal", "Race Car", "Dream House", "Giant Tree", "Robot", "Pirate Ship",
	"Monster", "Food", "Skyscraper", "Rocket", "Dragon", "Treehouse", "Snowman", "Underwater Base"]

var main: Node
var mode := SANDBOX
var phase := ""
var timer := 0.0
var data := {}
var visuals: Node3D
var beacon: MeshInstance3D
var cp_cooldown := 0.0
var ctf_timer := 0.0
var my_vote_for := -1
var time_scale := 1.0   # test runs speed rounds up


func is_on() -> bool:
	return mode != SANDBOX


func needs_teams() -> bool:
	return mode == CTF


func _seekers() -> Array:
	return data.get("seekers", [])


func is_seeker(id: int) -> bool:
	return mode == PROP_HUNT and _seekers().has(id)


func can_move(id: int) -> bool:
	return not (mode == PROP_HUNT and phase == "hide" and is_seeker(id))


func can_drive() -> bool:
	return not (mode == RACE and phase == "countdown")


func spawn_point(id: int) -> Vector3:
	var base := Maps.spawn_point(main.map_id)
	match mode:
		CTF:
			match main.teams.get(id, ""):
				"red": return base + Vector3(-CTF_BASE + 4.0, 0, 0)
				"blue": return base + Vector3(CTF_BASE - 4.0, 0, 0)
		BUILD:
			var plots: Dictionary = data.get("plots", {})
			if phase == "vote":
				var order: Array = data.get("order", [])
				var show: int = data.get("show", 0)
				if show < order.size() and plots.has(order[show]):
					return (plots[order[show]] as Vector3) + Vector3(randf_range(-4, 4), 0, PLOT * 0.5 + 4.0)
			if plots.has(id):
				return plots[id]
		PROP_HUNT:
			return base + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	return base


# Build Battle: only inside your own plot while building.
func can_place(peer: int, pos: Vector3, size: Vector3i, rot: int) -> bool:
	if mode != BUILD:
		return true
	if phase != "build":
		return false
	var plots: Dictionary = data.get("plots", {})
	if not plots.has(peer):
		return false
	var c: Vector3 = plots[peer]
	var box := Bricks.box_of(pos, size, rot)
	var h := PLOT * 0.5
	return box.position.x >= c.x - h and box.end.x <= c.x + h and box.position.z >= c.z - h and box.end.z <= c.z + h and box.end.y < 30.0


# ---------------- syncing ----------------

func _sync(msg := "") -> void:
	mode_update.rpc(phase, timer, data, msg)


@rpc("authority", "call_local", "reliable")
func mode_update(p: String, t: float, d: Dictionary, msg: String) -> void:
	var old := phase
	var old_show: int = data.get("show", -1)
	phase = p
	timer = t
	data = d
	if msg != "" and main.hud:
		main.hud.big_message(msg, 3.5)
		main.hud.add_system(msg)
		main.audio.play("beep", null, 0.0, 1.3)
	var me = main.local_player()
	if me:
		# teleport at the start of each round / each build shown for voting
		if phase != old and phase in ["hide", "countdown", "build", "play"]:
			me.respawn()
		if phase == "vote" and (old != "vote" or old_show != data.get("show", 0)):
			me.respawn()
			my_vote_for = -1
	_refresh_visuals()


# ---------------- host rules ----------------

func _process(delta: float) -> void:
	if not main.in_game or mode == SANDBOX:
		return
	timer = maxf(timer - delta, 0.0)
	cp_cooldown -= delta
	_update_local(delta)
	if main.multiplayer.is_server():
		match mode:
			PROP_HUNT: _tick_prop_hunt()
			RACE: _tick_race()
			BUILD: _tick_build()
			CTF:
				ctf_timer -= delta
				if ctf_timer <= 0.0:
					ctf_timer = 0.1
					_tick_ctf()
	if main.hud:
		main.hud.set_mode_status(status_text())


func _phase(p: String, t: float, msg: String) -> void:
	phase = p
	timer = t * time_scale
	_sync(msg)


func _tick_prop_hunt() -> void:
	var ids: Array = main.players.keys()
	match phase:
		"", "waiting":
			if ids.size() < 2:
				if phase == "":
					_phase("waiting", 0.0, "Prop Hunt needs at least 2 players.")
				return
			ids.shuffle()
			var n := maxi(1, ids.size() / 3)
			data = {"seekers": ids.slice(0, n), "disguise": {}}
			# scatter props to hide among
			var props := 0
			for e in main.entities.values():
				if Entities.TYPES[e.type]["kind"] == Entities.ITEM:
					props += 1
			var base := Maps.spawn_point(main.map_id)
			var rng := RandomNumberGenerator.new()
			for i in maxi(0, 45 - props):
				var t: int = PROP_TYPES[rng.randi() % PROP_TYPES.size()]
				var pos := base + Vector3(rng.randf_range(-28, 28), 1.0, rng.randf_range(-28, 28))
				var id: int = main.next_ent_id
				main.ent_spawner[id] = 1
				main.spawn_ent.rpc(id, t, pos, Quaternion(Vector3.UP, rng.randf() * TAU), 1, 0)
			_phase("hide", HIDE_TIME, "PROP HUNT! Hiders: look at a prop and press F to become it. Seekers are blindfolded for %d s." % HIDE_TIME)
		"hide":
			if timer <= 0.0:
				_phase("seek", SEEK_TIME, "Ready or not, here they come! Seekers: click on hiders to find them.")
		"seek":
			var hiders := ids.filter(func(id): return not _seekers().has(id))
			if hiders.is_empty():
				_phase("over", OVER_TIME, "SEEKERS WIN! Everyone was found.")
			elif timer <= 0.0:
				_phase("over", OVER_TIME, "HIDERS WIN! %d stayed hidden." % hiders.size())
		"over":
			if timer <= 0.0:
				_phase("", 0.0, "")


func _tick_race() -> void:
	match phase:
		"":
			if main.players.is_empty():
				return
			var cps := []
			var placed: Array = main.entities.values().filter(func(e): return e.type == Entities.CHECKPOINT)
			placed.sort_custom(func(a, b): return a.ent_id < b.ent_id)
			for e in placed:
				cps.append(e.global_position)
			var base := Maps.spawn_point(main.map_id)
			if cps.size() < 2:
				cps.clear()
				for i in 8:
					var a := TAU * i / 8.0
					var p := base + Vector3(sin(a) * 70.0, 0.3, -cos(a) * 70.0 + 70.0)
					cps.append(p)
					var id: int = main.next_ent_id
					main.ent_spawner[id] = 1
					main.spawn_ent.rpc(id, Entities.CHECKPOINT, p, Quaternion(Vector3.UP, a + PI * 0.5), 1, 0)
			# one kart each on a starting grid
			var karts := {}
			var i := 0
			for pid in main.players:
				var id: int = main.next_ent_id
				main.ent_spawner[id] = 1
				var pos := base + Vector3(-6 + (i % 4) * 4.0, 0.6, 8 + (i / 4) * 5.0)
				main.spawn_ent.rpc(id, KART, pos, Quaternion.IDENTITY, pid, 0)
				main.set_driver.rpc(id, pid)
				karts[pid] = id
				i += 1
			var next := {}
			for pid in main.players:
				next[pid] = 0
			data = {"cps": cps, "next": next, "done": [], "karts": karts}
			_phase("countdown", 4.0, "RACE! Drive through all %d checkpoints. Get ready..." % cps.size())
		"countdown":
			if timer <= 0.0:
				_phase("racing", RACE_LIMIT, "GO GO GO!")
		"racing":
			if data["done"].size() >= main.players.size() or timer <= 0.0:
				var lines := []
				for d in data["done"]:
					lines.append("%d. %s (%.1fs)" % [lines.size() + 1, main.players.get(d[0], {"name": "?"})["name"], d[1]])
				_phase("over", OVER_TIME, "Race over! " + (", ".join(lines) if not lines.is_empty() else "Nobody finished!"))
		"over":
			if timer <= 0.0:
				for id in data.get("karts", {}).values():
					if main.entities.has(id):
						main.delete_ent.rpc(id)
				_phase("", 0.0, "")


func _tick_build() -> void:
	match phase:
		"":
			if main.players.is_empty():
				return
			main._clear_all_bricks()
			var order: Array = main.players.keys()
			var plots := {}
			var base := Maps.spawn_point(main.map_id)
			for i in order.size():
				plots[order[i]] = base + Vector3((i - (order.size() - 1) * 0.5) * (PLOT + 6.0), 0.0, 40.0)
			data = {"theme": THEMES[randi() % THEMES.size()], "plots": plots, "order": order, "show": 0, "votes": {}}
			_phase("build", BUILD_TIME, "BUILD BATTLE! Theme: %s. Build it in your plot (%d minutes)." % [data["theme"], int(BUILD_TIME / 60)])
		"build":
			if timer <= 0.0:
				data["show"] = 0
				_phase("vote", VOTE_TIME, "Time's up! Rate each build with keys 1-5.")
		"vote":
			if timer <= 0.0:
				data["show"] += 1
				if data["show"] >= data["order"].size():
					var best := -1
					var best_score := -1.0
					for pid in data["order"]:
						var v: Dictionary = data["votes"].get(pid, {})
						var total := 0.0
						for s in v.values():
							total += s
						var avg := total / maxf(v.size(), 1.0)
						if avg > best_score:
							best_score = avg
							best = pid
					_phase("over", OVER_TIME + 4.0, "Winner: %s with %.1f stars! (theme was %s)" % [main.players.get(best, {"name": "?"})["name"], best_score, data["theme"]])
				else:
					var owner_id: int = data["order"][data["show"]]
					_phase("vote", VOTE_TIME, "Now rating %s's build" % main.players.get(owner_id, {"name": "?"})["name"])
		"over":
			if timer <= 0.0:
				_phase("", 0.0, "")


func _tick_ctf() -> void:
	var red: int = main.teams.values().count("red")
	var blue: int = main.teams.values().count("blue")
	var base := Maps.spawn_point(main.map_id)
	var homes := {"red": base + Vector3(-CTF_BASE, 0, 0), "blue": base + Vector3(CTF_BASE, 0, 0)}
	match phase:
		"", "waiting":
			if red == 0 or blue == 0:
				if phase == "":
					_phase("waiting", 0.0, "Capture the Flag: pick a team! Waiting for both teams.")
				return
			data = {"flags": {"red": ["home", homes["red"], 0], "blue": ["home", homes["blue"], 0]}, "score": {"red": 0, "blue": 0}}
			_phase("play", 0.0, "CAPTURE THE FLAG! Grab the other team's flag and bring it to your base. Click enemies to tag them.")
		"play":
			var flags: Dictionary = data["flags"]
			var changed := false
			var msg := ""
			for pid in main.player_nodes:
				var team: String = main.teams.get(pid, "")
				if team == "":
					continue
				var enemy := "blue" if team == "red" else "red"
				var pos: Vector3 = main.player_nodes[pid].global_position
				var ef: Array = flags[enemy]
				var of: Array = flags[team]
				if ef[0] != "carried" and pos.distance_to(ef[1]) < 2.5:
					flags[enemy] = ["carried", pos, pid]
					changed = true
					msg = "%s took the %s flag!" % [main.players[pid]["name"], enemy.to_upper()]
				elif of[0] == "dropped" and pos.distance_to(of[1]) < 2.5:
					flags[team] = ["home", homes[team], 0]
					changed = true
					msg = "%s returned the %s flag!" % [main.players[pid]["name"], team.to_upper()]
				elif ef[0] == "carried" and ef[2] == pid:
					flags[enemy][1] = pos
					if pos.distance_to(homes[team]) < 4.0 and flags[team][0] == "home":
						data["score"][team] += 1
						flags[enemy] = ["home", homes[enemy], 0]
						changed = true
						msg = "%s CAPTURED the flag! %s scores!" % [main.players[pid]["name"], team.to_upper()]
						if data["score"][team] >= CTF_WIN:
							_phase("over", OVER_TIME, "%s WINS CAPTURE THE FLAG!" % team.to_upper())
							return
			# flags held by players who left drop where they were
			for t in flags:
				if flags[t][0] == "carried" and not main.player_nodes.has(flags[t][2]):
					flags[t] = ["dropped", flags[t][1], 0]
					changed = true
			if changed:
				_sync(msg)
		"over":
			if timer <= 0.0:
				_phase("", 0.0, "")


# ---------------- requests from players ----------------

func request_disguise(type: int) -> void:
	if main.multiplayer.is_server():
		_server_disguise(1, type)
	else:
		req_disguise.rpc_id(1, type)


@rpc("any_peer", "reliable")
func req_disguise(type: int) -> void:
	if main.multiplayer.is_server():
		_server_disguise(main.multiplayer.get_remote_sender_id(), type)


func _server_disguise(peer: int, type: int) -> void:
	if mode != PROP_HUNT or not phase in ["hide", "seek"] or is_seeker(peer) or not PROP_TYPES.has(type):
		return
	data["disguise"][peer] = type
	_sync()


func request_tag(target: int) -> void:
	if main.multiplayer.is_server():
		_server_tag(1, target)
	else:
		req_tag.rpc_id(1, target)


@rpc("any_peer", "reliable")
func req_tag(target: int) -> void:
	if main.multiplayer.is_server():
		_server_tag(main.multiplayer.get_remote_sender_id(), target)


func _server_tag(peer: int, target: int) -> void:
	if not main.player_nodes.has(peer) or not main.player_nodes.has(target):
		return
	var dist: float = main.player_nodes[peer].global_position.distance_to(main.player_nodes[target].global_position)
	if dist > 6.0:
		return
	if mode == PROP_HUNT and phase == "seek" and is_seeker(peer) and not is_seeker(target):
		data["seekers"].append(target)
		data["disguise"].erase(target)
		_sync("%s was found by %s!" % [main.players[target]["name"], main.players[peer]["name"]])
	elif mode == CTF and phase == "play" and main.teams.get(peer, "") != main.teams.get(target, "") and main.teams.get(target, "") != "":
		for t in data["flags"]:
			var f: Array = data["flags"][t]
			if f[0] == "carried" and f[2] == target:
				data["flags"][t] = ["dropped", main.player_nodes[target].global_position, 0]
		_sync("%s tagged %s!" % [main.players[peer]["name"], main.players[target]["name"]])
		if target == 1:
			send_home()
		else:
			send_home.rpc_id(target)


@rpc("authority", "reliable")
func send_home() -> void:
	var me = main.local_player()
	if me:
		me.respawn()


func request_cp(index: int) -> void:
	if main.multiplayer.is_server():
		_server_cp(1, index)
	else:
		req_cp.rpc_id(1, index)


@rpc("any_peer", "reliable")
func req_cp(index: int) -> void:
	if main.multiplayer.is_server():
		_server_cp(main.multiplayer.get_remote_sender_id(), index)


func _server_cp(peer: int, index: int) -> void:
	if mode != RACE or phase != "racing" or data["next"].get(peer, -1) != index:
		return
	data["next"][peer] = index + 1
	if index + 1 >= data["cps"].size():
		data["done"].append([peer, RACE_LIMIT - timer])
		_sync("%s finished #%d!" % [main.players[peer]["name"], data["done"].size()])
	else:
		_sync()


func request_vote(stars: int) -> void:
	if main.multiplayer.is_server():
		_server_vote(1, stars)
	else:
		req_vote.rpc_id(1, stars)


@rpc("any_peer", "reliable")
func req_vote(stars: int) -> void:
	if main.multiplayer.is_server():
		_server_vote(main.multiplayer.get_remote_sender_id(), stars)


func _server_vote(peer: int, stars: int) -> void:
	if mode != BUILD or phase != "vote":
		return
	var owner_id: int = data["order"][data["show"]]
	if owner_id == peer:
		return
	if not data["votes"].has(owner_id):
		data["votes"][owner_id] = {}
	data["votes"][owner_id][peer] = clampi(stars, 1, 5)


# Local player clicked with empty hands: tag whoever is in front of you (Prop Hunt seekers, CTF).
func try_tag(player: Node) -> bool:
	if not ((mode == PROP_HUNT and phase == "seek" and is_seeker(player.peer_id)) or (mode == CTF and phase == "play")):
		return false
	var from: Vector3 = player.cam.global_position
	var to: Vector3 = from - player.cam.global_basis.z * (5.0 + player.arm.spring_length)
	var q := PhysicsRayQueryParameters3D.create(from, to, 4, [player.get_rid()])
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and "peer_id" in hit["collider"]:
		request_tag(hit["collider"].peer_id)
		main.audio.play("hit", null, -4.0)
	return true


func try_vote(key: int) -> bool:
	if mode != BUILD or phase != "vote" or key < KEY_1 or key > KEY_5:
		return false
	my_vote_for = data.get("show", 0)
	request_vote(key - KEY_0)
	main.hud.big_message("You gave it %d ⭐" % (key - KEY_0), 1.5)
	return true


# ---------------- what each player sees ----------------

func status_text() -> String:
	var t := ceili(timer)
	match mode:
		PROP_HUNT:
			var role := "SEEKER" if is_seeker(main.my_id()) else "HIDER"
			match phase:
				"hide": return "PROP HUNT · Hiding time: %d · You are a %s" % [t, role]
				"seek": return "PROP HUNT · %d:%02d left · Hiders left: %d · You are a %s" % [t / 60, t % 60, main.players.size() - _seekers().size(), role]
				"over": return "PROP HUNT · Next round in %d" % t
			return "PROP HUNT · Waiting for players"
		RACE:
			match phase:
				"countdown": return "RACE · Starting in %d" % t
				"racing":
					var next: int = data["next"].get(main.my_id(), 0)
					var total: int = data["cps"].size()
					return "RACE · Checkpoint %d/%d · %d:%02d left" % [mini(next + 1, total), total, t / 60, t % 60] if next < total else "RACE · You finished! Waiting for the others"
				"over": return "RACE · Next race in %d" % t
			return "RACE"
		BUILD:
			match phase:
				"build": return "BUILD BATTLE · Theme: %s · %d:%02d left" % [data.get("theme", ""), t / 60, t % 60]
				"vote": return "BUILD BATTLE · Rate this build with 1-5 · %d" % t
				"over": return "BUILD BATTLE · Next round in %d" % t
			return "BUILD BATTLE"
		CTF:
			var sc: Dictionary = data.get("score", {"red": 0, "blue": 0})
			return "CAPTURE THE FLAG · RED %d : %d BLUE (first to %d)" % [sc.get("red", 0), sc.get("blue", 0), CTF_WIN]
	return ""


func _update_local(delta: float) -> void:
	var me = main.local_player()
	if me == null:
		return
	if main.hud:
		main.hud.set_blind(mode == PROP_HUNT and phase == "hide" and is_seeker(main.my_id()))
	# race: pass through your next checkpoint
	if mode == RACE and phase == "racing":
		var next: int = data["next"].get(main.my_id(), 0)
		var cps: Array = data["cps"]
		if next < cps.size():
			if beacon:
				beacon.visible = true
				beacon.global_position = (cps[next] as Vector3) + Vector3.UP * 6.0
			var pos: Vector3 = me.global_position
			if cp_cooldown <= 0.0 and Vector2(pos.x - cps[next].x, pos.z - cps[next].z).length() < 9.0:
				cp_cooldown = 0.5
				request_cp(next)
				main.audio.play("beep")
		elif beacon:
			beacon.visible = false
	elif beacon:
		beacon.visible = false
	# ctf: carried flags follow their carrier
	if mode == CTF and visuals:
		for t in ["red", "blue"]:
			var flag := visuals.get_node_or_null("Flag_" + t) as Node3D
			var f = data.get("flags", {}).get(t)
			if flag and f:
				if f[0] == "carried" and main.player_nodes.has(f[2]):
					flag.global_position = main.player_nodes[f[2]].global_position + Vector3.UP * 2.6
				else:
					flag.global_position = f[1]
	# prop hunt disguises
	if mode == PROP_HUNT:
		for pid in main.player_nodes:
			main.player_nodes[pid].set_disguise(data.get("disguise", {}).get(pid, -1))


# Bases, plots and the race beacon (only on your screen; rebuilt when the mode data changes).
func _refresh_visuals() -> void:
	if visuals == null:
		visuals = Node3D.new()
		visuals.name = "ModeVisuals"
		main.add_child(visuals)
		beacon = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 1.2
		cm.bottom_radius = 1.2
		cm.height = 12.0
		beacon.mesh = cm
		var bm := Figure.glow_mat(Color(0.3, 1.0, 0.5)).duplicate() as StandardMaterial3D
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		bm.albedo_color.a = 0.35
		beacon.material_override = bm
		beacon.visible = false
		main.add_child(beacon)
	for c in visuals.get_children():
		c.queue_free()
	var base := Maps.spawn_point(main.map_id)
	if mode == CTF:
		for t in ["red", "blue"]:
			var col := Color(0.9, 0.15, 0.15) if t == "red" else Color(0.15, 0.35, 0.9)
			var home := base + Vector3(-CTF_BASE if t == "red" else CTF_BASE, 0, 0)
			Figure.box(visuals, Vector3(8, 0.05, 8), home + Vector3(0, 0.03, 0), col.lightened(0.3))
			var flag := Node3D.new()
			flag.name = "Flag_" + t
			visuals.add_child(flag)
			flag.global_position = home
			Figure.cyl(flag, 0.05, 3.0, Vector3(0, 1.5, 0), Color(0.85, 0.85, 0.85))
			Figure.box(flag, Vector3(1.2, 0.8, 0.04), Vector3(0.62, 2.55, 0), col)
	elif mode == BUILD:
		var plots: Dictionary = data.get("plots", {})
		for pid in plots:
			var c: Vector3 = plots[pid]
			var h := PLOT * 0.5
			for side in [[Vector3(PLOT, 0.06, 0.2), Vector3(0, 0, h)], [Vector3(PLOT, 0.06, 0.2), Vector3(0, 0, -h)], [Vector3(0.2, 0.06, PLOT), Vector3(h, 0, 0)], [Vector3(0.2, 0.06, PLOT), Vector3(-h, 0, 0)]]:
				Figure.box(visuals, side[0], c + side[1] + Vector3(0, 0.04, 0), Color(1.0, 0.85, 0.2))
			var name_tag := Label3D.new()
			name_tag.text = str(main.players.get(pid, {"name": "?"})["name"]) + "'s plot"
			name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			name_tag.font_size = 64
			name_tag.outline_size = 12
			name_tag.position = c + Vector3(0, 3.0, h + 1.0)
			visuals.add_child(name_tag)
