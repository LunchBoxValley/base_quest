# scenes/main/cpu_batter.gd — CPU Batter (HR nerf + pop-fly bias)
extends Node
class_name CpuBatter

@export var batter_path: NodePath
@export var home_plate_path: NodePath
@export var ball_group_name: String = "balls"

@export_group("Discipline / Personality")
@export_range(0.0, 1.0, 0.01) var discipline: float = 0.58
@export_range(0.0, 1.0, 0.01) var chase_rate: float = 0.18

@export_group("Timing")
@export var min_reaction_s: float = 0.07
@export var swing_lead_ms: int = 105
@export var timing_error_ms: int = 140        # ↑ more randomness → fewer perfects
@export var eta_max_s: float = 0.65
@export var min_downward_vy: float = 1.0

@export_group("Zone / Aim (px)")
@export var zone_half_width: float = 16.0
@export var zone_soft_edge: float = 8.0
@export var two_strike_expand_px: float = 6.0
@export var aim_error_px: float = 8.0
@export var slot_left_threshold_px: float = -12.0
@export var slot_right_threshold_px: float = 12.0
@export var lr_bias_scale: float = 0.26       # ↓ pull

@export_group("Pop-Fly Tendencies")
@export_range(0.0, 1.0, 0.01) var pop_fly_base_chance: float = 0.30
@export_range(0.0, 1.0, 0.01) var pop_fly_inner_boost: float = 0.25
@export_range(0.0, 1.0, 0.01) var pop_fly_outer_cut: float = 0.18

@export_group("Debug")
@export var debug_logs: bool = false

var _batter: Batter
var _plate: Node2D
var _ball: Node2D
var _bound_ball: Node = null
var _prev_pos: Vector2 = Vector2.ZERO
var _prev_t: float = 0.0
var _swing_scheduled := false
var _rng := RandomNumberGenerator.new()

const EMERGENCY_WINDOW_S := 0.08

func _ready() -> void:
	_rng.randomize()
	_batter = get_node_or_null(batter_path) as Batter
	_plate = get_node_or_null(home_plate_path) as Node2D
	set_process(true)
	get_tree().node_added.connect(_on_node_added)
	_try_bind_ball()
	if typeof(GameManager) != TYPE_NIL:
		if not GameManager.play_state_changed.is_connected(_on_play_state_changed):
			GameManager.play_state_changed.connect(_on_play_state_changed)
		if not GameManager.half_inning_started.is_connected(_on_half):
			GameManager.half_inning_started.connect(_on_half)

func _process(_dt: float) -> void:
	if _batter == null: return
	if _ball == null or not is_instance_valid(_ball):
		_try_bind_ball(); _prev_t = 0.0; _swing_scheduled = false; return
	if _ball.has_method("last_delivery") and String(_ball.last_delivery()).to_lower() != "pitch":
		return

	var plate_y := _plate.global_position.y if _plate else _batter.global_position.y
	var contact_global := _contact_point_global()
	var plate_x := contact_global.x if contact_global != null else (_plate.global_position.x if _plate else _batter.global_position.x)

	var now_t := Time.get_ticks_msec() / 1000.0
	var pos := _ball.global_position
	if _prev_t <= 0.0: _prev_t = now_t; _prev_pos = pos; return

	var dt := now_t - _prev_t
	if dt <= 0.0: return
	var v := (pos - _prev_pos) / dt
	_prev_pos = pos
	_prev_t = now_t
	if v.y <= min_downward_vy: return

	var dy := plate_y - pos.y
	if dy <= 0.0: return

	var eta := dy / v.y
	if eta < min_reaction_s or eta > eta_max_s:
		if not _swing_scheduled and eta > 0.0 and eta <= EMERGENCY_WINDOW_S:
			_schedule_swing_immediately()
		return

	var x_at_contact := pos.x + v.x * eta + _rng.randf_range(-aim_error_px, aim_error_px)
	var dx := x_at_contact - plate_x
	var adx := absf(dx)

	var half_core := zone_half_width
	var half_soft := zone_half_width + zone_soft_edge + _two_strike_expand()
	var p_swing := 0.0
	if adx <= half_core:
		p_swing = 0.93                         # allow more called strikes
	elif adx <= half_soft:
		var t = (adx - half_core) / max(0.001, (half_soft - half_core))
		var edge_will := 0.52 * (1.0 - 0.6 * discipline)
		p_swing = lerp(0.93, edge_will, clamp(t, 0.0, 1.0))
	else:
		p_swing = chase_rate * (0.50 + 0.50 * (1.0 - discipline))

	_apply_lr_bias(dx)
	_apply_pop_fly_bias(dx)

	if _swing_scheduled: return

	var roll := _rng.randf()
	if debug_logs:
		print("[CPU BAT] eta=", int(eta*1000.0), "ms dx=", int(dx), " p=", "%.2f" % p_swing, " roll=", "%.2f" % roll)
	if roll < p_swing:
		var when_ms := int(round(eta * 1000.0)) - swing_lead_ms + _rand_jitter_ms()
		if _rng.randf() < 0.20:
			when_ms += _rng.randi_range(12, 36)   # hesitation → later contact
		var when_s = clamp(float(when_ms) / 1000.0, min_reaction_s, eta_max_s)
		_plan_swing(when_s)
	elif not _swing_scheduled and eta <= EMERGENCY_WINDOW_S and adx <= (half_core * 0.8):
		_schedule_swing_immediately()

# ---- helpers ----
func _apply_lr_bias(dx_at_plate: float) -> void:
	var slot := 0.0
	if dx_at_plate <= slot_left_threshold_px:  slot = -1.0
	elif dx_at_plate >= slot_right_threshold_px: slot = 1.0
	var bias := (slot * lr_bias_scale) + _rng.randf_range(-0.12, 0.12)
	if _batter and _batter.has_method("ai_set_lr_bias"):
		_batter.ai_set_lr_bias(clamp(bias, -1.0, 1.0))

func _apply_pop_fly_bias(dx_at_plate: float) -> void:
	if _batter == null: return
	var inner := (dx_at_plate < 0.0)
	var base := pop_fly_base_chance
	if inner: base += pop_fly_inner_boost
	else:     base = max(0.0, base - pop_fly_outer_cut)
	base += _rng.randf_range(-0.06, 0.06)
	base = clamp(base, 0.0, 0.65)
	if _batter.has_method("ai_set_contact_pop_prob"):
		_batter.ai_set_contact_pop_prob(base)

func _contact_point_global() -> Vector2:
	if _batter and _batter.has_method("_contact_point"):
		var p = _batter.call("_contact_point")
		if p is Vector2:
			if _batter is Node2D and (p - (_batter as Node2D).global_position).length() < 300.0:
				return (_batter as Node2D).to_global(p)
			return p
	if _plate: return _plate.global_position
	return _batter.global_position if _batter else Vector2.ZERO

func _two_strike_expand() -> float:
	if typeof(GameManager) != TYPE_NIL and "strikes" in GameManager and int(GameManager.strikes) >= 2:
		return max(0.0, two_strike_expand_px)
	return 0.0

func _plan_swing(delay_s: float) -> void:
	if _batter and _batter.has_method("ai_swing_after"):
		_batter.ai_swing_after(delay_s)
		_swing_scheduled = true
		if debug_logs: print("[CPU BAT] swing in ", int(delay_s * 1000.0), " ms")

func _schedule_swing_immediately() -> void:
	if _swing_scheduled: return
	_plan_swing(min_reaction_s)

func _rand_jitter_ms() -> int:
	return int(round(_rng.randf_range(-float(timing_error_ms), float(timing_error_ms))))

# ---- ball binding / lifecycle ----
func _on_node_added(n: Node) -> void:
	if _ball != null and is_instance_valid(_ball): return
	if n.is_in_group(ball_group_name) and n is Node2D: _bind_ball(n as Node2D)

func _try_bind_ball() -> void:
	var candidates := get_tree().get_nodes_in_group(ball_group_name)
	if candidates.is_empty(): return
	var best: Node2D = null
	var best_d := INF
	var py := (_plate.global_position.y if _plate else 0.0)
	for c in candidates:
		if c is Node2D:
			var d := absf((c as Node2D).global_position.y - py)
			if d < best_d: best_d = d; best = c
	if best: _bind_ball(best)

func _bind_ball(b: Node2D) -> void:
	_ball = b; _prev_t = 0.0; _swing_scheduled = false
	if b.has_signal("out_of_play") and _bound_ball != b:
		b.out_of_play.connect(_on_ball_out_of_play)
		_bound_ball = b
	if debug_logs: print("[CPU BAT] bound ball: ", b)

func _on_ball_out_of_play() -> void:
	_prev_t = 0.0; _swing_scheduled = false
	if debug_logs: print("[CPU BAT] out_of_play → reset")

func _on_play_state_changed(active: bool) -> void:
	if not active: _prev_t = 0.0; _swing_scheduled = false

func _on_half(_inning: int, _half: int) -> void:
	_prev_t = 0.0; _swing_scheduled = false
