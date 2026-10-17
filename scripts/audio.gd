extends Node
# All of FunLand's sounds and music, made from code (no audio files): little synth blips,
# noise bursts for explosions and splashes, an engine hum, and a chiptune loop whose
# melody is different on every map.

const RATE := 22050
const MUSIC_RATE := 11025

var sounds := {}
var engine_stream: AudioStreamWAV
var music_player: AudioStreamPlayer
var music_on := true
var sfx_volume := 0.0  # dB


func _ready() -> void:
	sounds["place"] = _tone([880.0, 1320.0], 0.07, "square", 0.25)
	sounds["remove"] = _tone([300.0, 180.0], 0.09, "square", 0.25)
	sounds["paint"] = _tone([1200.0, 1600.0], 0.06, "sine", 0.3)
	sounds["door"] = _tone([220.0, 260.0, 200.0], 0.25, "saw", 0.18)
	sounds["jump"] = _tone([300.0, 520.0], 0.1, "sine", 0.25)
	sounds["throw"] = _noise(0.18, 0.25, 0.6, false)
	sounds["grab"] = _tone([500.0, 700.0], 0.05, "sine", 0.25)
	sounds["hit"] = _tone([160.0, 70.0], 0.12, "sine", 0.6)
	sounds["explosion"] = _noise(1.2, 0.9, 0.08, true)
	sounds["splash"] = _noise(0.35, 0.4, 0.3, false)
	sounds["click"] = _tone([1000.0], 0.03, "square", 0.2)
	sounds["unlock"] = _tone([523.0, 659.0, 784.0, 1046.0], 0.4, "square", 0.22)
	sounds["win"] = _tone([523.0, 523.0, 784.0, 1046.0], 0.7, "square", 0.25)
	sounds["out"] = _tone([440.0, 330.0, 220.0], 0.45, "square", 0.22)
	sounds["fuse"] = _noise(0.5, 0.15, 0.9, false)
	sounds["beep"] = _tone([1500.0], 0.08, "square", 0.2)
	engine_stream = _engine()
	music_player = AudioStreamPlayer.new()
	music_player.volume_db = -14.0
	add_child(music_player)


# ---------------- playing ----------------

func play(name: String, pos = null, volume := 0.0, pitch := 1.0) -> void:
	if not sounds.has(name):
		return
	var p: Node
	if pos is Vector3:
		var p3 := AudioStreamPlayer3D.new()
		p3.stream = sounds[name]
		p3.unit_size = 8.0
		p3.max_distance = 120.0
		p3.volume_db = volume + sfx_volume
		p3.pitch_scale = pitch
		p3.position = pos
		p3.autoplay = true
		p = p3
	else:
		var p2 := AudioStreamPlayer.new()
		p2.stream = sounds[name]
		p2.volume_db = volume + sfx_volume
		p2.pitch_scale = pitch
		p2.autoplay = true
		p = p2
	p.finished.connect(p.queue_free)
	add_child(p)


func start_music(seed_value: int) -> void:
	music_player.stream = _music(seed_value)
	if music_on:
		music_player.play()


func toggle_music() -> void:
	music_on = not music_on
	if music_on:
		music_player.play()
	else:
		music_player.stop()


# ---------------- making sounds ----------------

static func _wav(data: PackedFloat32Array, rate: int, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, int(clampf(data[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = data.size()
	return w


static func _osc(wave: String, phase: float) -> float:
	match wave:
		"square": return 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
		"saw": return fmod(phase, 1.0) * 2.0 - 1.0
		"tri": return absf(fmod(phase, 1.0) * 4.0 - 2.0) - 1.0
		_: return sin(phase * TAU)


# A quick sweep through the given pitches with a fast fade.
static func _tone(freqs: Array, dur: float, wave: String, vol: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedFloat32Array()
	data.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		var f: float = freqs[mini(int(t * freqs.size()), freqs.size() - 1)]
		phase += f / RATE
		var env := minf(t * 40.0, 1.0) * (1.0 - t)
		data[i] = _osc(wave, phase) * env * vol
	return _wav(data, RATE)


# Noise: rough=low-passed rumble (explosions), otherwise hiss (whoosh, splash).
static func _noise(dur: float, vol: float, brightness: float, rumble: bool) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var data := PackedFloat32Array()
	data.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = n
	var lp := 0.0
	for i in n:
		var t := float(i) / n
		lp += (rng.randf_range(-1.0, 1.0) - lp) * brightness
		var env := minf(t * 60.0, 1.0) * pow(1.0 - t, 2.0 if rumble else 1.0)
		var s := lp
		if rumble:
			s += sin(i * TAU * (60.0 - 30.0 * t) / RATE) * 0.6
		data[i] = s * env * vol
	return _wav(data, RATE)


static func _engine() -> AudioStreamWAV:
	var n := RATE / 2
	var data := PackedFloat32Array()
	data.resize(n)
	for i in n:
		var p := i * 90.0 / RATE
		data[i] = (_osc("saw", p) * 0.5 + _osc("square", p * 0.5) * 0.3) * 0.25
	return _wav(data, RATE, true)


# A 16-second chiptune loop: bass, chords, a pentatonic melody and hi-hats, seeded per map.
static func _music(seed_value: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 17
	var bpm := 120.0
	var step := 60.0 / bpm / 4.0  # sixteenth notes
	var steps := 128
	var n := int(steps * step * MUSIC_RATE)
	var data := PackedFloat32Array()
	data.resize(n)
	var root: int = [48, 50, 53, 55, 45][rng.randi() % 5]
	var progressions := [[0, 5, 3, 4], [0, 3, 4, 4], [0, 4, 5, 3], [0, 5, 0, 4]]
	var prog: Array = progressions[rng.randi() % progressions.size()]
	var scale := [0, 2, 4, 7, 9, 12, 14, 16]
	var major := [0, 2, 4, 5, 7, 9, 11]
	var melody := []
	var note := 2
	for s in steps:
		if s % 2 == 0 and rng.randf() < 0.7:
			note = clampi(note + rng.randi_range(-2, 2), 0, scale.size() - 1)
			melody.append(note)
		else:
			melody.append(-1)
	var mel_phase := 0.0
	var bass_phase := 0.0
	var chord_phases := [0.0, 0.0, 0.0]
	var mel_note := -1
	var mel_start := 0
	var hat := 0.0
	for i in n:
		var s := int(i / (step * MUSIC_RATE))
		var in_step := float(i - int(s * step * MUSIC_RATE)) / (step * MUSIC_RATE)
		var bar := (s / 16) % 4
		var chord_root: int = root + major[prog[bar]]
		if melody[s] != -1 and in_step < 0.01:
			mel_note = melody[s]
			mel_start = i
		var out := 0.0
		# bass on eighth notes
		var bf := _midi(chord_root - 12 + (7 if (s / 2) % 4 == 2 else 0))
		bass_phase += bf / MUSIC_RATE
		out += _osc("tri", bass_phase) * 0.35 * (1.0 - in_step * 0.5)
		# soft chord pad
		for c in 3:
			chord_phases[c] += _midi(chord_root + [0, 4, 7][c]) / MUSIC_RATE
			out += _osc("sine", chord_phases[c]) * 0.06
		# melody
		if mel_note >= 0:
			var age := float(i - mel_start) / MUSIC_RATE
			mel_phase += _midi(root + 12 + scale[mel_note]) / MUSIC_RATE
			out += _osc("square", mel_phase) * 0.12 * maxf(1.0 - age * 2.5, 0.0)
		# hi-hat on off-beats
		if s % 4 == 2:
			hat = rng.randf_range(-1.0, 1.0)
			out += hat * 0.05 * (1.0 - in_step)
		# kick on beats
		if s % 4 == 0:
			out += sin(in_step * 40.0) * 0.3 * (1.0 - in_step)
		data[i] = out * 0.7
	return _wav(data, MUSIC_RATE, true)


static func _midi(m: float) -> float:
	return 440.0 * pow(2.0, (m - 69.0) / 12.0)
