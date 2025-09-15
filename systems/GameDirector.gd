extends Node
class_name GameDirector

@export var umpire_hud_path: NodePath
@export var camera_path: NodePath
@export var cpu_pitcher_path: NodePath
@export var cpu_batter_path: NodePath
@export var pitcher_path: NodePath
@export var batter_path: NodePath
@export var human_is_home: bool = true

var _hud: Node
var _cam: Node
var _cpu_pitcher: Node
var _cpu_batter: Node
var _pitcher: Pitcher
var _batter: Batter

func _ready() -> void:
	_hud = get_node_or_null(umpire_hud_path)
	_cam = get_node_or_null(camera_path)
	_cpu_pitcher = get_node_or_null(cpu_pitcher_path)
	_cpu_batter  = get_node_or_null(cpu_batter_path)
	_pitcher = get_node_or_null(pitcher_path) as Pitcher
	_batter  = get_node_or_null(batter_path)  as Batter

	GameManager.count_changed.connect(_on_count_changed)
	GameManager.outs_changed.connect(_on_outs_changed)
	GameManager.half_inning_started.connect(_on_half_inning_started)
	GameManager.play_state_changed.connect(_on_play_state_changed)
	GameManager.game_over_signal.connect(_on_game_over)
	GameManager.message.connect(_forward_message_to_hud)

	_on_half_inning_started(GameManager.inning, GameManager.half)

func _on_count_changed(_b: int, _s: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_outs_changed(_o: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_half_inning_started(_inning: int, half: int) -> void:
	# half: 0 = TOP (away bats), 1 = BOTTOM (home bats)
	var human_on_offense := (half == 0 and not human_is_home) or (half == 1 and human_is_home)

	# CPU controllers
	if _cpu_pitcher:
		if human_on_offense:
			if _cpu_pitcher.has_method("activate"): _cpu_pitcher.call("activate")
		else:
			if _cpu_pitcher.has_method("deactivate"): _cpu_pitcher.call("deactivate")
	if _cpu_batter:
		if human_on_offense:
			if _cpu_batter.has_method("deactivate"): _cpu_batter.call("deactivate")
		else:
			if _cpu_batter.has_method("activate"):   _cpu_batter.call("activate")

	# Human input gates
	if _pitcher: _pitcher.input_enabled = (not human_on_offense) # human pitches on defense
	if _batter:  _batter.input_enabled  = human_on_offense       # human bats on offense

	# Unlock play so defense can pitch immediately
	if GameManager.has_method("end_play"):
		GameManager.end_play()

	# Camera reset
	if _cam and _cam.has_method("follow_default"):
		_cam.call("follow_default")

	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_play_state_changed(active: bool) -> void:
	if not active and _cam and _cam.has_method("follow_default"):
		_cam.call("follow_default")

func _on_game_over() -> void:
	if _cpu_pitcher and _cpu_pitcher.has_method("deactivate"): _cpu_pitcher.call("deactivate")
	if _cpu_batter  and _cpu_batter.has_method("deactivate"):  _cpu_batter.call("deactivate")
	if _hud and _hud.has_method("flash_message"):
		_hud.call("flash_message", "GAME OVER", Color(1,1,1), 1.2)

func _forward_message_to_hud(kind: String) -> void:
	if _hud and _hud.has_method("announce"):
		_hud.call("announce", kind)
