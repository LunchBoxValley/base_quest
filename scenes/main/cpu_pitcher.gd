# scenes/main/cpu_pitcher.gd — Attempt A4 (Robot)
extends Node
class_name CpuPitcher

@export var pitcher_path: NodePath
@export var min_cooldown: float = 5.0
@export var max_cooldown: float = 8.0

# AI tendencies
@export var power_range: Vector2 = Vector2(0.55, 0.95)    # 0..1
@export var accuracy_range: Vector2 = Vector2(0.55, 0.95) # 0..1
@export var aim_center_deg: float = 0.0
@export var aim_spread_deg: float = 10.0
@export var steer_variation: float = 0.10                  # -0.1..+0.1

# Charge animation pace (simulated "hold")
@export var min_charge_time: float = 0.80
@export var max_charge_time: float = 2.50

var _pitcher: Pitcher
var _active := false
var _timer: SceneTreeTimer = null
var _heartbeat_accum := 0.0

func _ready() -> void:
	_pitcher = get_node_or_null(pitcher_path) as Pitcher
	GameManager.play_state_changed.connect(_on_play_state_changed)
	GameManager.outs_changed.connect(_on_outs_changed)
	GameManager.half_inning_started.connect(_on_half_inning_started)
	set_process(true)

func activate() -> void:
	_active = true
	_schedule_next_pitch(true)  # will be near-immediate with Attempt A4

func deactivate() -> void:
	_active = false
	_clear_timer()
	_stop_fx()

func kick_now() -> void:
	# Public, immediate “do a pitch now” used by GameDirector to prevent long initial waits
	if not _active: return
	if GameManager.outs >= 3: return
	if GameManager.play_active: return
	if _any_ball_exists(): return
	_begin_ai_pitch()

func _process(delta: float) -> void:
	if not _active:
		return
	# Heartbeat: if idle and allowed, ensure a pitch is scheduled.
	_heartbeat_accum += delta
	if _heartbeat_accum >= 1.0:
		_heartbeat_accum = 0.0
		var no_timer := (_timer == null) or (_timer.time_left <= 0.0)
		if not GameManager.play_active and not _any_ball_exists() and GameManager.outs < 3 and no_timer:
			_schedule_next_pitch()

func _on_half_inning_started(_inning: int, _half: int) -> void:
	if _active:
		_clear_timer()
		_schedule_next_pitch(true)

func _on_outs_changed(_outs: int) -> void:
	if not _active:
		return
	if GameManager.outs >= 3:
		_clear_timer()
		_stop_fx()
	else:
		_schedule_next_pitch()

func _on_play_state_changed(active: bool) -> void:
	if _active and not active and GameManager.outs < 3:
		_schedule_next_pitch()

func _schedule_next_pitch(force: bool=false) -> void:
	if not _active:
		return
	if GameManager.outs >= 3:
		return
	if GameManager.play_active and not force:
		return
	if _timer and _timer.time_left > 0.0:
		return

	var wait := randf_range(min_cooldown, max_cooldown)
	# Attempt A4: when “force” is true (e.g., inning just started), pitch almost immediately
	if force:
		wait = 0.15

	_timer = get_tree().create_timer(wait)
	_timer.timeout.connect(_begin_ai_pitch)

func _clear_timer() -> void:
	_timer = null

func _any_ball_exists() -> bool:
	# cheap: group “balls” or common name
	if get_tree().get_first_node_in_group("balls") != null:
		return true
	var n := get_tree().get_root().find_child("Ball", true, false)
	return n != null

func _begin_ai_pitch() -> void:
	_timer = null
	if not _active or GameManager.outs >= 3:
		return
	if _pitcher == null or not is_instance_valid(_pitcher):
		return
	if GameManager.play_active:
		return
	if _any_ball_exists():
		return

	# Decide pitch
	var pwr = clamp(randf_range(power_range.x, power_range.y), 0.0, 1.0)
	var acc = clamp(randf_range(accuracy_range.x, accuracy_range.y), 0.0, 1.0)
	var aim_deg := aim_center_deg + randf_range(-aim_spread_deg, aim_spread_deg)
	var steer := randf_range(-steer_variation, steer_variation)

	# Start same zoom + FX as human
	if _pitcher.has_method("ai_begin_charge_zoom"):
		_pitcher.ai_begin_charge_zoom()
	if _pitcher.has_method("ai_begin_charge_fx"):
		_pitcher.ai_begin_charge_fx()

	# Simulate a single-phase hold to chosen power
	var dur := randf_range(min_charge_time, max_charge_time)
	var t := 0.0
	while t < dur:
		var level = clamp(t / max(0.0001, dur), 0.0, 1.0) * pwr
		_set_fx_level(0, level)
		await get_tree().process_frame
		t += get_process_delta_time()
	_set_fx_level(0, pwr)

	# Throw (Pitcher handles FX burst + snap-back)
	_pitcher.ai_pitch(pwr, acc, aim_deg, steer)

func _set_fx_level(phase: int, level: float) -> void:
	if not is_instance_valid(_pitcher):
		return
	if _pitcher.has_method("ai_set_charge_level"):
		_pitcher.ai_set_charge_level(phase, level)
	elif _pitcher.has_method("_fx_set_level"):
		_pitcher.call("_fx_set_level", phase, level)

func _stop_fx() -> void:
	if not is_instance_valid(_pitcher):
		return
	if _pitcher.has_method("_fx_stop"):
		_pitcher.call("_fx_stop")
