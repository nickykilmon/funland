extends CanvasLayer
# Start screen: customize your funfig, then host a room (pick map, ground color, saved build) or join a friend.

signal host_requested(info: Dictionary, map_id: int, plane_color: Color, build_name: String)
signal join_requested(info: Dictionary, ip: String)

const Figure = preload("res://scripts/figure.gd")
const Maps = preload("res://scripts/maps.gd")
const SAVE_PATH := "user://profile.cfg"
const BUILDS_DIR := "user://builds"

const COLOR_LABELS := {
	"skin": "Face", "shirt": "Shirt", "pants": "Pants",
	"hat_color": "Hat / hair", "print_color": "Shirt print", "acc_color": "Back item",
}
const OPTION_LABELS := {"hat": "Hat / hair", "face": "Face", "print": "Shirt print", "legs": "Legs", "acc": "Back item"}

var name_edit: LineEdit
var color_picks := {}
var option_btns := {}
var map_opt: OptionButton
var plane_pick: ColorPickerButton
var build_opt: OptionButton
var code_edit: LineEdit
var room_list: VBoxContainer
var status: Label
var preview_holder: Node3D


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.14, 0.24)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var title := Label.new()
	title.text = "FunLand"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.1))
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_outline_color", Color(0.75, 0.1, 0.1))
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Build anything out of funbricks, together!"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)

	var hb := HBoxContainer.new()
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 20)
	vb.add_child(hb)

	# --- your funfig ---
	var left := _panel(hb, "Your Funfig", true)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Your name"
	name_edit.max_length = 16
	_row(left, "Name", name_edit)
	for key in Figure.OPTIONS:
		var ob := OptionButton.new()
		for item in Figure.OPTIONS[key]:
			ob.add_item(item)
		ob.item_selected.connect(func(_i): _rebuild_preview())
		option_btns[key] = ob
		_row(left, OPTION_LABELS[key], ob)
	for key in Figure.COLOR_DEFAULTS:
		color_picks[key] = _color_row(left, COLOR_LABELS[key], Figure.COLOR_DEFAULTS[key])
	var rand := Button.new()
	rand.text = "🎲 Randomize"
	rand.pressed.connect(_randomize)
	left.add_child(rand)

	# --- preview ---
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(220, 300)
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(svc)
	var sv := SubViewport.new()
	sv.own_world_3d = true
	sv.transparent_bg = true
	sv.msaa_3d = Viewport.MSAA_4X
	svc.add_child(sv)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.85, 1.0)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	sv.add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 30, 0)
	sv.add_child(light)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.15, 3.8)
	cam.rotation_degrees.x = -4
	cam.fov = 40
	sv.add_child(cam)
	preview_holder = Node3D.new()
	sv.add_child(preview_holder)

	# --- play ---
	var right := _panel(hb, "Play", false)
	right.add_child(_heading("Host a room"))
	map_opt = OptionButton.new()
	for m in Maps.NAMES:
		map_opt.add_item(m)
	_row(right, "Map", map_opt)
	plane_pick = _color_row(right, "Ground color", Color(0.3, 0.68, 0.25))
	build_opt = OptionButton.new()
	build_opt.add_item("(start empty)")
	for b in list_builds():
		build_opt.add_item(b)
	_row(right, "Load build", build_opt)
	var host_btn := Button.new()
	host_btn.text = "Host Game"
	host_btn.custom_minimum_size.y = 38
	host_btn.pressed.connect(_on_host)
	right.add_child(host_btn)
	right.add_child(HSeparator.new())
	right.add_child(_heading("Join a friend"))
	var list_head := HBoxContainer.new()
	var hint := Label.new()
	hint.text = "Open rooms:"
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_head.add_child(hint)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(_refresh_rooms)
	list_head.add_child(refresh)
	right.add_child(list_head)
	var room_scroll := ScrollContainer.new()
	room_scroll.custom_minimum_size.y = 96
	room_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	room_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(room_scroll)
	room_list = VBoxContainer.new()
	room_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_scroll.add_child(room_list)
	code_edit = LineEdit.new()
	code_edit.placeholder_text = "or type a room code"
	code_edit.max_length = 4
	var code_row := HBoxContainer.new()
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(code_edit)
	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.custom_minimum_size.x = 80
	join_btn.pressed.connect(func(): _join(code_edit.text))
	code_row.add_child(join_btn)
	right.add_child(code_row)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	right.add_child(status)

	_load_profile()
	_rebuild_preview()
	if Engine.has_meta("menu_msg"):
		status.text = Engine.get_meta("menu_msg")
		Engine.remove_meta("menu_msg")
	_refresh_rooms.call_deferred()


func _process(delta: float) -> void:
	preview_holder.rotate_y(delta * 0.8)


static func list_builds() -> Array:
	var out := []
	var dir := DirAccess.open(BUILDS_DIR)
	if dir:
		for f in dir.get_files():
			if f.ends_with(".json"):
				out.append(f.get_basename())
	out.sort()
	return out


func _panel(parent: Control, title: String, scroll: bool) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.custom_minimum_size.x = 320
	parent.add_child(pc)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 12)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if scroll:
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		m.add_child(sc)
		sc.add_child(vb)
	else:
		m.add_child(vb)
	vb.add_child(_heading(title))
	return vb


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	return l


func _row(parent: Control, label: String, ctrl: Control) -> void:
	var hb := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 105
	hb.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(ctrl)
	parent.add_child(hb)


func _color_row(parent: Control, label: String, c: Color) -> ColorPickerButton:
	var cp := ColorPickerButton.new()
	cp.color = c
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(80, 26)
	cp.color_changed.connect(func(_c): _rebuild_preview())
	_row(parent, label, cp)
	return cp


func get_info() -> Dictionary:
	var info := {"name": name_edit.text.strip_edges()}
	for key in color_picks:
		info[key] = color_picks[key].color
	for key in option_btns:
		info[key] = option_btns[key].selected
	return info


func _randomize() -> void:
	var skins := [Color(1.0, 0.8, 0.15), Color(0.98, 0.8, 0.65), Color(0.85, 0.62, 0.42), Color(0.6, 0.4, 0.25), Color(0.4, 0.26, 0.15)]
	color_picks["skin"].color = skins.pick_random()
	for key in ["shirt", "pants", "hat_color", "print_color", "acc_color"]:
		color_picks[key].color = Color.from_hsv(randf(), randf_range(0.3, 0.9), randf_range(0.3, 1.0))
	for key in option_btns:
		var ob: OptionButton = option_btns[key]
		ob.select(randi() % ob.item_count)
	_rebuild_preview()


func _rebuild_preview() -> void:
	for c in preview_holder.get_children():
		c.queue_free()
	preview_holder.add_child(Figure.build(get_info()))


func set_status(text: String) -> void:
	status.text = text


func _on_host() -> void:
	_save_profile()
	var build := "" if build_opt.selected <= 0 else build_opt.get_item_text(build_opt.selected)
	host_requested.emit(get_info(), map_opt.selected, plane_pick.color, build)


func _join(code: String) -> void:
	_save_profile()
	join_requested.emit(get_info(), code)


func _refresh_rooms() -> void:
	_clear_rooms()
	room_list.add_child(_note("Looking for rooms..."))
	get_parent().fetch_rooms()


func _clear_rooms() -> void:
	for c in room_list.get_children():
		c.queue_free()


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.modulate.a = 0.7
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# rooms = Array of {code, name, map, players}, or null if the server couldn't be reached.
func show_rooms(rooms) -> void:
	_clear_rooms()
	if rooms == null:
		room_list.add_child(_note("Couldn't reach the FunLand server. It may be waking up, hit Refresh in 30 seconds."))
		return
	if rooms.is_empty():
		room_list.add_child(_note("No rooms yet. Host one!"))
		return
	for r in rooms:
		var b := Button.new()
		b.text = "%s's room  ·  %s  ·  %d/16   [%s]" % [r["name"], r["map"], int(r["players"]), r["code"]]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var code: String = r["code"]
		b.pressed.connect(func(): _join(code))
		room_list.add_child(b)


func _save_profile() -> void:
	var cfg := ConfigFile.new()
	var info := get_info()
	for k in info:
		cfg.set_value("player", k, info[k])
	cfg.set_value("menu", "map", map_opt.selected)
	cfg.set_value("menu", "plane", plane_pick.color)
	cfg.save(SAVE_PATH)


func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	name_edit.text = cfg.get_value("player", "name", "")
	for key in color_picks:
		color_picks[key].color = cfg.get_value("player", key, color_picks[key].color)
	for key in option_btns:
		var ob: OptionButton = option_btns[key]
		ob.select(clampi(cfg.get_value("player", key, 0), 0, ob.item_count - 1))
	map_opt.select(clampi(cfg.get_value("menu", "map", 0), 0, map_opt.item_count - 1))
	plane_pick.color = cfg.get_value("menu", "plane", plane_pick.color)
