# systems/GameDirector.gd — Attempt A4 (Robot, Godot 4.5 safe)
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
var _pitcher: Node
var _batter: Node

func _ready() -> void:
	_hud         = get_node_or_null(umpire_hud_path)
	_cam         = get_node_or_null(camera_path)
	_cpu_pitcher = get_node_or_null(cpu_pitcher_path)
	_cpu_batter  = get_node_or_null(cpu_batter_path)
	_pitcher     = get_node_or_null(pitcher_path)
	_batter      = get_node_or_null(batter_path)

	# Group fallbacks (non-fatal if not present)
	if _cpu_pitcher == null:
		_cpu_pitcher = get_tree().get_first_node_in_group("cpu_pitcher")
	if _cpu_batter == null:
		_cpu_batter = get_tree().get_first_node_in_group("cpu_batter")
	if _pitcher == null:
		_pitcher = get_tree().get_first_node_in_group("pitcher")
	if _batter == null:
		_batter = get_tree().get_first_node_in_group("batter")

	GameManager.count_changed.connect(_on_count_changed)
	GameManager.outs_changed.connect(_on_outs_changed)
	GameManager.half_inning_started.connect(_on_half_inning_started)
	GameManager.play_state_changed.connect(_on_play_state_changed)
	GameManager.game_over_signal.connect(_on_game_over)
	GameManager.message.connect(_forward_message_to_hud)

	# Apply after one idle frame so nodes are fully ready
	call_deferred("_on_half_inning_started", GameManager.inning, GameManager.half)

func _on_count_changed(_b: int, _s: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_outs_changed(_o: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_half_inning_started(_inning: int, half: int) -> void:
	# half: 0 = TOP (away bats), 1 = BOTTOM (home bats)
	var human_on_offense := (half == 0 and not human_is_home) or (half == 1 and human_is_home)

	# --- CPU controllers ---
	if _cpu_pitcher:
		if human_on_offense:
			if _cpu_pitcher.has_method("activate"): _cpu_pitcher.call("activate")
			# Kick immediately so we don't wait 5–8s on the first pitch
			if _cpu_pitcher.has_method("kick_now"): _cpu_pitcher.call("kick_now")
		else:
			if _cpu_pitcher.has_method("deactivate"): _cpu_pitcher.call("deactivate")

	if _cpu_batter:
		if human_on_offense:
			if _cpu_batter.has_method("deactivate"):  _cpu_batter.call("deactivate")
		else:
			if _cpu_batter.has_method("activate"):    _cpu_batter.call("activate")

	# --- Human input gates (engine-native) ---
	# Human pitches on defense → enable Pitcher input when NOT on offense
	if _pitcher:
		var enable_pitcher_input := (not human_on_offense)
		_pitcher.set_process_input(enable_pitcher_input)
		_pitcher.set_process_unhandled_input(enable_pitcher_input)

	# Human bats on offense → enable Batter input when on offense
	if _batter:
		var enable_batter_input := human_on_offense
		_batter.set_process_input(enable_batter_input)
		_batter.set_process_unhandled_input(enable_batter_input)

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
