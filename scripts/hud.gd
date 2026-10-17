extends CanvasLayer
# In-game overlay: crosshair, controls help, text chat, player list, funbrick tool bar and the Esc menu.

signal chat_sent(text: String)
signal leave_pressed
signal save_pressed(build_name: String)
signal clear_pressed
signal spawn_chosen(type: int)
signal team_chosen(team: String)

const Bricks = preload("res://scripts/bricks.gd")
const Entities = preload("res://scripts/entities.gd")

const HELP := """WASD move · Space jump · Shift run · V camera · T chat · Tab players
B spawn menu · Click grab/drop · Right click throw · X delete · F drive / door
E funbrick tool · G wave · H dance · C sit"""
const DODGE_HELP := """WASD move · Space jump · Shift run · V camera · T chat · Tab players
Click grab a ball · Right click throw · E build defenses (build phase)"""
const DRIVE_HELP := {
	Entities.CAR: "W/S drive · A/D steer · Space brake · R flip over · F get out",
	Entities.HELI: "W/S forward/back · A/D turn · Space up · Shift down · F get out",
	Entities.PLANE: "Shift/Ctrl throttle · W/S nose down/up · A/D roll · F get out",
}

var is_host := false
var log_label: RichTextLabel
var chat_edit: LineEdit
var tool_panel: PanelContainer
var tool_label: Label
var swatches: Array[Panel] = []
var player_list: Label
var pause_panel: PanelContainer
var save_edit: LineEdit
var pause_status: Label
var save_row: HBoxContainer
var clear_btn: Button
var help_label: Label
var drive_label: Label
var spawn_panel: PanelContainer
var team_panel: PanelContainer
var dodge_label: Label
var big_label: Label
var big_timer := 0.0
var budget := -1
var dodgeball := false
var last_tool := []


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var cross := Label.new()
	cross.text = "+"
	cross.add_theme_font_size_override("font_size", 28)
	_outline(cross)
	center.add_child(cross)

	help_label = Label.new()
	help_label.text = HELP
	help_label.position = Vector2(12, 8)
	help_label.modulate.a = 0.85
	_outline(help_label)
	add_child(help_label)

	player_list = Label.new()
	player_list.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	player_list.offset_left = -260
	player_list.offset_right = -12
	player_list.offset_top = 12
	player_list.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	player_list.add_theme_font_size_override("font_size", 18)
	_outline(player_list)
	player_list.visible = false
	add_child(player_list)

	var chat_box := VBoxContainer.new()
	chat_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_box.offset_left = 12
	chat_box.offset_right = 470
	chat_box.offset_top = -270
	chat_box.offset_bottom = -12
	chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(chat_box)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_label.add_theme_constant_override("outline_size", 6)
	log_label.add_theme_color_override("font_outline_color", Color.BLACK)
	chat_box.add_child(log_label)
	chat_edit = LineEdit.new()
	chat_edit.placeholder_text = "Say something... (Enter to send, Esc to cancel)"
	chat_edit.max_length = 200
	chat_edit.visible = false
	chat_edit.text_submitted.connect(_on_submit)
	chat_edit.gui_input.connect(_on_chat_input)
	chat_box.add_child(chat_edit)

	_build_tool_panel()
	_build_pause_panel()
	_build_spawn_menu()
	_build_team_panel()
	_build_dodge_labels()


func _outline(l: Control) -> void:
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color.BLACK)


func _build_tool_panel() -> void:
	tool_panel = PanelContainer.new()
	tool_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	tool_panel.offset_left = -330
	tool_panel.offset_right = 330
	tool_panel.offset_top = -150
	tool_panel.offset_bottom = -14
	tool_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tool_panel.visible = false
	add_child(tool_panel)
	var vb := VBoxContainer.new()
	tool_panel.add_child(vb)
	tool_label = Label.new()
	tool_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(tool_label)
	var grid := GridContainer.new()
	grid.columns = 12
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vb.add_child(grid)
	for c in Bricks.COLORS:
		var sw := Panel.new()
		sw.custom_minimum_size = Vector2(28, 28)
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.set_corner_radius_all(4)
		sw.add_theme_stylebox_override("panel", sb)
		grid.add_child(sw)
		swatches.append(sw)
	var keys := Label.new()
	keys.text = "Q shape · 1-9 size · R rotate · scroll/Z/X color · P paint · middle-click copy · Ctrl+Z undo\nLeft click place (hold for more) · Right click remove"
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.add_theme_font_size_override("font_size", 12)
	keys.modulate.a = 0.8
	vb.add_child(keys)


func _build_pause_panel() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.offset_left = -170
	pause_panel.offset_right = 170
	pause_panel.offset_top = -150
	pause_panel.offset_bottom = 150
	pause_panel.visible = false
	add_child(pause_panel)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 16)
	pause_panel.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	m.add_child(vb)
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	vb.add_child(title)
	var resume := Button.new()
	resume.text = "Resume (click the game)"
	resume.pressed.connect(func(): Input.mouse_mode = Input.MOUSE_MODE_CAPTURED)
	vb.add_child(resume)
	save_row = HBoxContainer.new()
	vb.add_child(save_row)
	save_edit = LineEdit.new()
	save_edit.placeholder_text = "Build name"
	save_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(save_edit)
	var save_btn := Button.new()
	save_btn.text = "Save build"
	save_btn.pressed.connect(func(): save_pressed.emit(save_edit.text))
	save_row.add_child(save_btn)
	clear_btn = Button.new()
	clear_btn.text = "Clear all bricks"
	clear_btn.pressed.connect(func(): clear_pressed.emit())
	vb.add_child(clear_btn)
	var leave := Button.new()
	leave.text = "Leave game"
	leave.pressed.connect(func(): leave_pressed.emit())
	vb.add_child(leave)
	pause_status = Label.new()
	pause_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pause_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	vb.add_child(pause_status)


func _process(delta: float) -> void:
	big_timer -= delta
	big_label.visible = big_timer > 0.0
	var my_team: String = get_parent().teams.get(get_parent().my_id(), "")
	team_panel.visible = dodgeball and my_team == ""
	if team_panel.visible or spawn_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var paused := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not is_typing() and not team_panel.visible and not spawn_panel.visible
	if paused and not pause_panel.visible:
		save_row.visible = is_host
		clear_btn.visible = is_host
		pause_status.text = "" if is_host else "Only the host can save builds."
	pause_panel.visible = paused
	player_list.visible = Input.is_physical_key_pressed(KEY_TAB) and not is_typing()
	if player_list.visible:
		var names := []
		var players: Dictionary = get_parent().players
		for id in players:
			names.append(("★ " if id == 1 else "") + str(players[id]["name"]))
		player_list.text = "Players (%d)\n%s" % [names.size(), "\n".join(names)]


func set_room(code: String) -> void:
	var l := Label.new()
	l.text = "Room " + code
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.offset_left = -100
	l.offset_right = 100
	l.offset_top = 8
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_outline(l)
	add_child(l)


func set_pause_status(text: String) -> void:
	pause_status.text = text


func is_typing() -> bool:
	return chat_edit.visible


func open_chat() -> void:
	chat_edit.text = ""
	chat_edit.visible = true
	chat_edit.grab_focus()


func _close_chat() -> void:
	chat_edit.release_focus()
	chat_edit.visible = false


func _on_submit(text: String) -> void:
	_close_chat()
	text = text.strip_edges()
	if text != "":
		chat_sent.emit(text)


func _on_chat_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		_close_chat()
		chat_edit.accept_event()


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func add_chat(who: String, text: String, color: Color) -> void:
	log_label.append_text("[color=#%s][b]%s:[/b][/color] %s\n" % [color.lightened(0.35).to_html(false), _esc(who), _esc(text)])


func add_system(text: String) -> void:
	log_label.append_text("[color=#ffdd55][i]%s[/i][/color]\n" % _esc(text))


func set_tool(on: bool, paint: bool, shape_name: String, size: Vector3i, rot: int, color_idx: int) -> void:
	last_tool = [on, paint, shape_name, size, rot, color_idx]
	tool_panel.visible = on
	if budget >= 0 and not paint:
		shape_name = "%d bricks left  ·  %s" % [budget, shape_name]
	if paint:
		tool_label.text = "PAINT MODE: click bricks to recolor them (P to go back to building)"
	else:
		tool_label.text = "%s  %d x %d   ·   turned %d°" % [shape_name, size.x, size.z, rot * 90]
	for i in swatches.size():
		var sb := swatches[i].get_theme_stylebox("panel") as StyleBoxFlat
		sb.set_border_width_all(3 if i == color_idx else 0)
		sb.border_color = Color.WHITE


# ---------------- spawn menu (B) ----------------

func _build_spawn_menu() -> void:
	spawn_panel = PanelContainer.new()
	spawn_panel.set_anchors_preset(Control.PRESET_CENTER)
	spawn_panel.offset_left = -330
	spawn_panel.offset_right = 330
	spawn_panel.offset_top = -190
	spawn_panel.offset_bottom = 190
	spawn_panel.visible = false
	add_child(spawn_panel)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 14)
	spawn_panel.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	for section in [["Props", true], ["Vehicles", false]]:
		var title := Label.new()
		title.text = section[0]
		title.add_theme_font_size_override("font_size", 20)
		vb.add_child(title)
		var grid := GridContainer.new()
		grid.columns = 4
		vb.add_child(grid)
		for t in Entities.TYPES.size():
			var is_item: bool = Entities.TYPES[t]["kind"] == Entities.ITEM
			if is_item != section[1]:
				continue
			var b := Button.new()
			b.text = Entities.TYPES[t]["name"]
			b.custom_minimum_size = Vector2(150, 34)
			var type: int = t
			b.pressed.connect(func():
				spawn_panel.visible = false
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				spawn_chosen.emit(type))
			grid.add_child(b)
	var close := Button.new()
	close.text = "Close (B)"
	close.pressed.connect(toggle_spawn_menu)
	vb.add_child(close)


func toggle_spawn_menu() -> void:
	spawn_panel.visible = not spawn_panel.visible
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if spawn_panel.visible else Input.MOUSE_MODE_CAPTURED


func _unhandled_key_input(event: InputEvent) -> void:
	# B closes the menu again while it has the mouse
	var ke := event as InputEventKey
	if ke and ke.pressed and not ke.echo and ke.physical_keycode == KEY_B and spawn_panel.visible:
		toggle_spawn_menu()
		get_viewport().set_input_as_handled()


# ---------------- dodgeball ----------------

func _build_team_panel() -> void:
	team_panel = PanelContainer.new()
	team_panel.set_anchors_preset(Control.PRESET_CENTER)
	team_panel.offset_left = -220
	team_panel.offset_right = 220
	team_panel.offset_top = -90
	team_panel.offset_bottom = 90
	team_panel.visible = false
	add_child(team_panel)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	team_panel.add_child(vb)
	var title := Label.new()
	title.text = "Pick your team!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vb.add_child(title)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	vb.add_child(row)
	for t in [["RED", "red", Color(0.85, 0.15, 0.15)], ["BLUE", "blue", Color(0.15, 0.35, 0.85)]]:
		var b := Button.new()
		b.text = t[0]
		b.custom_minimum_size = Vector2(160, 60)
		b.add_theme_font_size_override("font_size", 24)
		var sb := StyleBoxFlat.new()
		sb.bg_color = t[2]
		sb.set_corner_radius_all(8)
		b.add_theme_stylebox_override("normal", sb)
		var hover := sb.duplicate() as StyleBoxFlat
		hover.bg_color = (t[2] as Color).lightened(0.2)
		b.add_theme_stylebox_override("hover", hover)
		var team: String = t[1]
		b.pressed.connect(func():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			team_chosen.emit(team))
		row.add_child(b)


func _build_dodge_labels() -> void:
	dodge_label = Label.new()
	dodge_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	dodge_label.offset_left = -300
	dodge_label.offset_right = 300
	dodge_label.offset_top = 36
	dodge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dodge_label.add_theme_font_size_override("font_size", 22)
	_outline(dodge_label)
	dodge_label.visible = false
	add_child(dodge_label)
	big_label = Label.new()
	big_label.set_anchors_preset(Control.PRESET_CENTER)
	big_label.offset_left = -400
	big_label.offset_right = 400
	big_label.offset_top = -140
	big_label.offset_bottom = -80
	big_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	big_label.add_theme_font_size_override("font_size", 32)
	big_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	big_label.add_theme_constant_override("outline_size", 10)
	big_label.add_theme_color_override("font_outline_color", Color.BLACK)
	big_label.visible = false
	add_child(big_label)
	drive_label = Label.new()
	drive_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	drive_label.offset_left = -300
	drive_label.offset_right = 300
	drive_label.offset_top = -50
	drive_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drive_label.add_theme_font_size_override("font_size", 18)
	_outline(drive_label)
	drive_label.visible = false
	add_child(drive_label)


func set_dodgeball(on: bool) -> void:
	dodgeball = on
	dodge_label.visible = on
	help_label.text = DODGE_HELP if on else HELP


func big_message(text: String, seconds := 3.0) -> void:
	big_label.text = text
	big_timer = seconds


func set_dodge(state: String, timer: float, score: Dictionary, red_alive: int, blue_alive: int, my_team: String) -> void:
	var line := "RED %d  :  %d BLUE" % [score.get("red", 0), score.get("blue", 0)]
	match state:
		"waiting": line += "\nWaiting for players on both teams"
		"build": line += "\nBuild phase: %d" % ceili(timer)
		"playing": line += "\nRed left: %d  ·  Blue left: %d" % [red_alive, blue_alive]
		"roundover": line += "\nNext round in %d" % ceili(timer)
	if my_team != "":
		line += "\nYou're on %s" % my_team.to_upper()
	dodge_label.text = line


func set_budget(left: int) -> void:
	budget = left
	if not last_tool.is_empty():
		set_tool.callv(last_tool)


func set_driving(kind: int) -> void:
	drive_label.visible = kind >= 0
	drive_label.text = DRIVE_HELP.get(kind, "")
	if kind >= 0:
		tool_panel.visible = false
