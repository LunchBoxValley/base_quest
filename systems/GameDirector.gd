# systems/GameDirector.gd — A4.2 (Robot, Godot 4.5 safe)
extends Node
class_name GameDirector

# -------- Optional wiring into the GameManager autoload (runtime injection) --------
@export var runner_scene: PackedScene
@export var runners_parent_path: NodePath         # e.g. "Entities/Runners" or "Runners"
@export var home_path: NodePath                   # e.g. "HomePlate" or "Home"
@export var base1_path: NodePath                  # e.g. "Base1"
@export var base2_path: NodePath                  # e.g. "Base2"
@export var base3_path: NodePath                  # e.g. "Base3"

# -------- Existing exports --------
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
	# Resolve UI/actors
	_hud         = get_node_or_null(umpire_hud_path)
	_cam         = get_node_or_null(camera_path)
	_cpu_pitcher = get_node_or_null(cpu_pitcher_path)
	_cpu_batter  = get_node_or_null(cpu_batter_path)
	_pitcher     = get_node_or_null(pitcher_path)
	_batter      = get_node_or_null(batter_path)

	# Group fallbacks (non-fatal)
	if _cpu_pitcher == null:
		_cpu_pitcher = get_tree().get_first_node_in_group("cpu_pitcher")
	if _cpu_batter == null:
		_cpu_batter = get_tree().get_first_node_in_group("cpu_batter")
	if _pitcher == null:
		_pitcher = get_tree().get_first_node_in_group("pitcher")
	if _batter == null:
		_batter = get_tree().get_first_node_in_group("batter")

	# ---- NEW: pass references to GameManager (autoload has no Inspector) ----
	_configure_game_manager()
	# Defer the refresh so the whole scene tree is live before GM resolves nodes
	call_deferred("_post_config_refresh")

	# Signals from GameManager
	GameManager.count_changed.connect(_on_count_changed)
	GameManager.outs_changed.connect(_on_outs_changed)
	GameManager.half_inning_started.connect(_on_half_inning_started)
	GameManager.play_state_changed.connect(_on_play_state_changed)
	GameManager.game_over_signal.connect(_on_game_over)
	GameManager.message.connect(_forward_message_to_hud)

	# Apply after one idle frame so nodes are fully ready
	call_deferred("_on_half_inning_started", GameManager.inning, GameManager.half)

func _post_config_refresh() -> void:
	if GameManager.has_method("refresh_scene_refs"):
		GameManager.refresh_scene_refs()
	if GameManager.has_method("_debug_dump_missing"):
		# Optional: one-time sanity print at startup
		GameManager._debug_dump_missing()

func _configure_game_manager() -> void:
	var gm := GameManager
	if gm == null:
		return

	# Runner scene (required—set in Inspector here)
	if runner_scene != null and gm.has_method("set_runner_scene"):
		gm.set_runner_scene(runner_scene)

	# Runners parent: explicit path if provided, else try to guess
	var runners_np := runners_parent_path
	if runners_np == NodePath():
		var root := get_tree().get_current_scene()
		if root:
			var guess := root.get_node_or_null("Entities/Runners")
			if guess == null:
				guess = root.get_node_or_null("Runners")
			if guess:
				runners_np = guess.get_path()
	if runners_np != NodePath() and gm.has_method("set_runners_parent_path"):
		gm.set_runners_parent_path(runners_np)

	# Base paths: prefer explicit; else leave for GM’s name/group search
	var hp := home_path
	var b1p := base1_path
	var b2p := base2_path
	var b3p := base3_path
	if gm.has_method("set_base_paths") and hp != NodePath() and b1p != NodePath() and b2p != NodePath() and b3p != NodePath():
		gm.set_base_paths(hp, b1p, b2p, b3p)

func _on_count_changed(_b: int, _s: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_outs_changed(_o: int) -> void:
	if _hud and _hud.has_method("set_count"):
		_hud.call("set_count", GameManager.balls, GameManager.strikes, GameManager.outs)

func _on_half_inning_started(_inning: int, half: int) -> void:
	var human_on_offense := (half == 0 and not human_is_home) or (half == 1 and human_is_home)

	# --- CPU controllers ---
	if _cpu_pitcher:
		if human_on_offense:
			if _cpu_pitcher.has_method("activate"): _cpu_pitcher.call("activate")
			if _cpu_pitcher.has_method("kick_now"): _cpu_pitcher.call("kick_now")
		else:
			if _cpu_pitcher.has_method("deactivate"): _cpu_pitcher.call("deactivate")

	if _cpu_batter:
		if human_on_offense:
			if _cpu_batter.has_method("deactivate"):  _cpu_batter.call("deactivate")
		else:
			if _cpu_batter.has_method("activate"):    _cpu_batter.call("activate")

	# --- Human input gates ---
	if _pitcher:
		var enable_pitcher_input := (not human_on_offense)
		_pitcher.set_process_input(enable_pitcher_input)
		_pitcher.set_process_unhandled_input(enable_pitcher_input)

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
