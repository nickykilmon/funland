extends CanvasLayer
# In-game overlay: crosshair, controls help, text chat, player list, funbrick tool bar and the Esc menu.

signal chat_sent(text: String)
signal leave_pressed
signal save_pressed(build_name: String)
signal clear_pressed

const Bricks = preload("res://scripts/bricks.gd")

const HELP := """WASD move · Space jump · Shift run · V camera · T chat · Tab players
G wave · H dance · C sit · F open door · E funbrick tool"""

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

	var help := Label.new()
	help.text = HELP
	help.position = Vector2(12, 8)
	help.modulate.a = 0.85
	_outline(help)
	add_child(help)

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


func _process(_delta: float) -> void:
	var paused := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not is_typing()
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
	tool_panel.visible = on
	if paint:
		tool_label.text = "PAINT MODE: click bricks to recolor them (P to go back to building)"
	else:
		tool_label.text = "%s  %d x %d   ·   turned %d°" % [shape_name, size.x, size.z, rot * 90]
	for i in swatches.size():
		var sb := swatches[i].get_theme_stylebox("panel") as StyleBoxFlat
		sb.set_border_width_all(3 if i == color_idx else 0)
		sb.border_color = Color.WHITE
