extends MultiplayerPeerExtension
# Multiplayer over the FunLand website: every packet goes through the Node relay server (server/server.js)
# over a WebSocket, so it works in browsers and on school Wi-Fi. The host is peer 1; the relay hands
# everyone else an id. All the game's RPCs work the same as with a direct connection.

signal room_ready(code: String)
signal relay_error(message: String)

var ws := WebSocketPeer.new()
var my_id := 0
var room_code := ""
var status := CONNECTION_DISCONNECTED
var target := 0
var refusing := false
var incoming: Array = []   # [from id, packet bytes]
var hello := {}            # first message to send once the socket opens


func start(url: String, first_message: Dictionary) -> Error:
	ws.inbound_buffer_size = 1 << 24
	ws.outbound_buffer_size = 1 << 24
	ws.max_queued_packets = 8192
	var err := ws.connect_to_url(url)
	if err == OK:
		hello = first_message
		status = CONNECTION_CONNECTING
	return err


func _poll() -> void:
	ws.poll()
	var state := ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not hello.is_empty():
		ws.send_text(JSON.stringify(hello))
		hello = {}
	while ws.get_available_packet_count() > 0:
		var pkt := ws.get_packet()
		if ws.was_string_packet():
			var msg = JSON.parse_string(pkt.get_string_from_utf8())
			if msg is Dictionary:
				_on_control(msg)
		elif pkt.size() >= 4:
			incoming.append([pkt.decode_s32(0), pkt.slice(4)])
	if state == WebSocketPeer.STATE_CLOSED and status != CONNECTION_DISCONNECTED:
		if status == CONNECTION_CONNECTING:
			relay_error.emit("Couldn't reach the FunLand server. It may be waking up, try again in 30 seconds.")
		status = CONNECTION_DISCONNECTED


func _on_control(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"welcome":
			my_id = int(msg["id"])
			room_code = str(msg.get("room", ""))
			status = CONNECTION_CONNECTED
			for p in msg.get("peers", []):
				peer_connected.emit(int(p))
			room_ready.emit(room_code)
		"peer":
			peer_connected.emit(int(msg["id"]))
		"left":
			peer_disconnected.emit(int(msg["id"]))
		"error":
			status = CONNECTION_DISCONNECTED
			relay_error.emit(str(msg.get("msg", "Server error")))
			ws.close()


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	var out := PackedByteArray()
	out.resize(4)
	out.encode_s32(0, target)
	out.append_array(buffer)
	return ws.send(out)


func _get_packet_script() -> PackedByteArray:
	if incoming.is_empty():
		return PackedByteArray()
	return incoming.pop_front()[1]


func _get_packet_peer() -> int:
	return incoming[0][0] if not incoming.is_empty() else 0


func _get_available_packet_count() -> int:
	return incoming.size()


func _get_max_packet_size() -> int:
	return 1 << 24


func _get_packet_channel() -> int:
	return 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return TRANSFER_MODE_RELIABLE


func _set_transfer_channel(_channel: int) -> void:
	pass


func _get_transfer_channel() -> int:
	return 0


func _set_transfer_mode(_mode: MultiplayerPeer.TransferMode) -> void:
	pass


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return TRANSFER_MODE_RELIABLE


func _set_target_peer(peer: int) -> void:
	target = peer


func _get_unique_id() -> int:
	return my_id


func _is_server() -> bool:
	return my_id == 1


func _is_server_relay_supported() -> bool:
	return false


func _set_refuse_new_connections(enable: bool) -> void:
	refusing = enable


func _is_refusing_new_connections() -> bool:
	return refusing


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return status


func _disconnect_peer(peer: int, _force: bool) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify({"t": "kick", "id": peer}))


func _close() -> void:
	ws.close()
	status = CONNECTION_DISCONNECTED
	incoming.clear()
