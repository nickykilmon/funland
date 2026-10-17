extends Node
# Your progress, saved in this browser/computer: playtime, stats, achievements, and which
# cosmetics they unlock. Everything not listed in UNLOCKS is free from the start.

signal unlocked(text: String)

var SAVE_PATH := "user://progress.cfg" if OS.get_cmdline_user_args().is_empty() else "user://progress_test.cfg"

const ACHIEVEMENTS := {
	"first_brick": ["First Brick", "Place your first brick"],
	"first_door": ["Knock Knock", "Open your first door"],
	"first_ride": ["Road Trip", "Take your first ride in a vehicle"],
	"pilot": ["Sky High", "Fly a plane or helicopter high up"],
	"swim": ["Splash!", "Go for a swim"],
	"kaboom": ["Kaboom", "Be near an explosion"],
	"welder": ["Welder", "Weld two things together"],
	"balloonist": ["Balloonist", "Tie on a balloon"],
	"electrician": ["Electrician", "Wire up a button or plate"],
	"rocketeer": ["Rocketeer", "Stick on a thruster"],
	"dance": ["Dance Party", "Dance (H)"],
	"explorer": ["Explorer", "Visit 5 different worlds"],
	"world_tour": ["World Tour", "Visit every world"],
	"moon": ["One Small Step", "Visit the Moon"],
	"dodger": ["Bullseye", "Hit someone in dodgeball"],
	"champion": ["Champion", "Win a dodgeball round"],
}

# [option, index, name, how to unlock, requirement]
# requirement: ["time", seconds] / ["ach", id] / ["stat", name, amount]
const UNLOCKS := [
	["hat", 19, "Ninja Headband", "Play for 10 minutes", ["time", 600]],
	["hat", 20, "Santa Hat", "Play for 1 hour", ["time", 3600]],
	["hat", 21, "Pumpkin Head", "Be near an explosion", ["ach", "kaboom"]],
	["hat", 22, "Dino Hood", "Play for 30 minutes", ["time", 1800]],
	["hat", 23, "Graduation Cap", "Visit 5 different worlds", ["ach", "explorer"]],
	["hat", 24, "Construction Helmet", "Place your first brick", ["ach", "first_brick"]],
	["hat", 25, "Pilot Goggles", "Fly a plane or helicopter", ["ach", "pilot"]],
	["hat", 26, "Golden Crown", "Win 10 dodgeball rounds", ["stat", "dodge_wins", 10]],
	["hat", 27, "Flower Crown", "Paint 20 bricks", ["stat", "paints", 20]],
	["hat", 28, "Traffic Cone Hat", "Spawn 50 things", ["stat", "spawns", 50]],
	["hat", 29, "Unicorn Horn", "Tie on a balloon", ["ach", "balloonist"]],
	["hat", 30, "Astronaut Helmet", "Visit the Moon", ["ach", "moon"]],
	["face", 10, "Star Eyes", "Open your first door", ["ach", "first_door"]],
	["face", 11, "Heart Eyes", "Dance (H)", ["ach", "dance"]],
	["face", 12, "Tongue Out", "Go for a swim", ["ach", "swim"]],
	["face", 13, "Monocle", "Weld two things together", ["ach", "welder"]],
	["face", 14, "Clown", "Throw 25 things", ["stat", "throws", 25]],
	["print", 9, "Flames", "Take your first ride", ["ach", "first_ride"]],
	["print", 10, "Checkers", "Place 100 bricks", ["stat", "bricks", 100]],
	["print", 11, "Dodgeball Champ", "Win a dodgeball round", ["ach", "champion"]],
	["print", 12, "Rainbow", "Place 1000 bricks", ["stat", "bricks", 1000]],
	["acc", 9, "Angel Wings", "Play for 2 hours", ["time", 7200]],
	["acc", 10, "Dragon Wings", "Win 25 dodgeball rounds", ["stat", "dodge_wins", 25]],
	["acc", 11, "Shield", "Hit 10 players in dodgeball", ["stat", "hits", 10]],
	["acc", 12, "Pet Duck", "Wire up a button or plate", ["ach", "electrician"]],
	["acc", 13, "Rocket Pack", "Stick on a thruster", ["ach", "rocketeer"]],
	["legs", 4, "Robot Legs", "Play for 45 minutes", ["time", 2700]],
	["legs", 5, "Rainbow Socks", "Visit every world", ["ach", "world_tour"]],
]

var playtime := 0.0
var stats := {}
var achieved := {}
var maps_seen := {}
var _save_timer := 0.0
var _was_unlocked := {}


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		playtime = cfg.get_value("p", "playtime", 0.0)
		stats = cfg.get_value("p", "stats", {})
		achieved = cfg.get_value("p", "achieved", {})
		maps_seen = cfg.get_value("p", "maps", {})
	for u in UNLOCKS:
		_was_unlocked[_key(u)] = _met(u[4])


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("p", "playtime", playtime)
	cfg.set_value("p", "stats", stats)
	cfg.set_value("p", "achieved", achieved)
	cfg.set_value("p", "maps", maps_seen)
	cfg.save(SAVE_PATH)


# Called every frame while you're in a world.
func tick(delta: float) -> void:
	playtime += delta
	_save_timer += delta
	if _save_timer > 15.0:
		_save_timer = 0.0
		_check_unlocks()
		save()


func add(stat: String, amount := 1) -> void:
	stats[stat] = int(stats.get(stat, 0)) + amount
	_check_unlocks()


func achieve(id: String) -> void:
	if achieved.has(id) or not ACHIEVEMENTS.has(id):
		return
	achieved[id] = true
	unlocked.emit("Achievement: %s!" % ACHIEVEMENTS[id][0])
	_check_unlocks()
	save()


func visit_map(map_id: int, map_count: int) -> void:
	maps_seen[map_id] = true
	if map_id == 7:
		achieve("moon")
	if maps_seen.size() >= 5:
		achieve("explorer")
	if maps_seen.size() >= map_count:
		achieve("world_tour")


static func _key(u: Array) -> String:
	return "%s:%d" % [u[0], u[1]]


func _met(req: Array) -> bool:
	match req[0]:
		"time": return playtime >= req[1]
		"ach": return achieved.has(req[1])
		"stat": return int(stats.get(req[1], 0)) >= req[2]
	return false


func _check_unlocks() -> void:
	for u in UNLOCKS:
		var k := _key(u)
		if not _was_unlocked[k] and _met(u[4]):
			_was_unlocked[k] = true
			unlocked.emit("Unlocked: %s!" % u[2])
			save()


# Is this cosmetic option free or earned? (option = "hat"/"face"/"print"/"legs"/"acc")
func is_unlocked(option: String, index: int) -> bool:
	for u in UNLOCKS:
		if u[0] == option and u[1] == index:
			return _met(u[4])
	return true


func requirement(option: String, index: int) -> String:
	for u in UNLOCKS:
		if u[0] == option and u[1] == index:
			return u[3]
	return ""


func progress_text() -> String:
	var lines := ["Playtime: %d min" % int(playtime / 60.0)]
	lines.append("Dodgeball wins: %d · Hits: %d · Bricks placed: %d" % [stats.get("dodge_wins", 0), stats.get("hits", 0), stats.get("bricks", 0)])
	lines.append("")
	lines.append("ACHIEVEMENTS (%d/%d)" % [achieved.size(), ACHIEVEMENTS.size()])
	for id in ACHIEVEMENTS:
		lines.append(("✅ " if achieved.has(id) else "⬜ ") + "%s: %s" % ACHIEVEMENTS[id])
	lines.append("")
	var got := 0
	for u in UNLOCKS:
		if _met(u[4]):
			got += 1
	lines.append("UNLOCKABLE COSMETICS (%d/%d)" % [got, UNLOCKS.size()])
	for u in UNLOCKS:
		lines.append(("🔓 " if _met(u[4]) else "🔒 ") + "%s: %s" % [u[2], u[3]])
	return "\n".join(lines)
