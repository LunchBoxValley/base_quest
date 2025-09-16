extends Node
class_name CpuBatter

@export var batter_path: NodePath
@export var home_plate_path: NodePath

# Group the Ball belongs to (your project uses "balls")
@export var ball_group_name: String = "balls"

@export_group("Difficulty / Personality")
@export_range(0.0, 1.0, 0.01) var discipline: float = 0.65
@export_range(0.0, 1.0, 0.01) var chase_rate: float = 0.25
@export_range(0.0, 1.0, 0.01) var power_bias: float = 0.35

@export_group("Timing (seconds / ms)")
@export var min_reaction_s: float = 0.12       # won't swing if ETA < this
@export var swing_lead_ms: int = 90            # start swing this many ms before plate-cross
@export var timing_error_ms: int = 80          # +/- jitter added to lead time

@export_group("Aim / Slots (px)")
@export var aim_error_px: float = 6.0
@export var slot_left_threshold_px: float = -12.0
@export var slot_right_threshold_px: float = 12.0

@export_group("Strike Window (px)")
@export var zone_half_width: float = 14.0      # approx half width for "in-zone" test
@export var zone_soft_edge: float = 8.0        # soft edge falloff

@export_group("Debug")
@export var debug_logs: bool = false

# --- Internals ---
var _batter: Batter = null
var _plate: Node2D = null
var _ball: Node2D = null
var _bound_ball: Node = null
var _ball_prev_pos: Vector2 = Vector2.ZERO
var _ball_prev_time: float = 0.0
var _swing_scheduled: bool = false
var _swing_eta_s: float = 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_batter = get_node_or_null(batter_path) as Batter
	_plate = get_node_or_null(home_plate_path) as Node2D

	# Node doesn't process by default
	set_process(true)

	# Bind any existing ball in the group, then auto-catch future spawns
	_try_bind_ball_from_group()
	get_tree().node_added.connect(_on_node_added)

	if debug_logs:
		print("[CpuBatter] ready; batter=", _batter, " plate=", _plate)

func _process(delta: float) -> void:
	# Reacquire if missing (e.g., after despawn)
	if _ball == null or not is_instance_valid(_ball):
		_try_bind_ball_from_group()
		_ball_prev_time = 0.0
		_swing_scheduled = false
		if debug_logs:
			print("[CpuBatter] reacquire ball: ", _ball)

	if _batter == null or _plate == null or _ball == null:
		return

	var now := Time.get_ticks_msec() / 1000.0
	var pos := _ball.global_position

	# Initialize prev snapshot
	if _ball_prev_time <= 0.0:
		_ball_prev_time = now
		_ball_prev_pos = pos
		return

	var dt := now - _ball_prev_time
	if dt <= 0.0:
		return

	# Estimate velocity from motion
	var v := (pos - _ball_prev_pos) / dt
	_ball_prev_pos = pos
	_ball_prev_time = now

	# Expect pitches traveling downward (increasing Y toward plate)
	if v.y <= 0.0:
		return

	var plate_pos := _plate.global_position
	var dy := plate_pos.y - pos.y
	if dy <= 0.0:
		return

	var t_to_plate := dy / v.y                # seconds
	var ms_to_plate := int(round(t_to_plate * 1000.0))

	# Respect reaction floor
	if t_to_plate < min_reaction_s:
		return

	# Predict horizontal position at plate and set LR bias (with jitter)
	var x_at_plate := pos.x + v.x * t_to_plate + _rng.randf_range(-aim_error_px, aim_error_px)
	_apply_lr_bias(x_at_plate - plate_pos.x)

	# Decide swing/take once per pitch
	if not _swing_scheduled:
		var swing_prob := _swing_probability(x_at_plate, plate_pos.x, ms_to_plate)
		var roll := _rng.randf()
		if debug_logs:
			print("[CpuBatter] ETA(ms)=", ms_to_plate, " prob=", swing_prob, " roll=", roll)
		if roll < swing_prob:
			var scheduled_ms := ms_to_plate - swing_lead_ms + _rand_timing_jitter()
			var scheduled_s = max(min_reaction_s, float(scheduled_ms) / 1000.0)
			_swing_eta_s = scheduled_s
			_swing_scheduled = true
			_batter.ai_swing_after(scheduled_s)
			if debug_logs:
				print("[CpuBatter] swing scheduled in ", int(scheduled_s * 1000.0), " ms")

# -----------------------
# Binding via "balls" group
# -----------------------
func _on_node_added(n: Node) -> void:
	# If we already have a ball, skip
	if _ball != null and is_instance_valid(_ball):
		return
	# If this node is in the ball group, bind it
	if n.is_in_group(ball_group_name) and n is Node2D:
		_bind_ball(n as Node2D)

func _try_bind_ball_from_group() -> void:
	var candidates := get_tree().get_nodes_in_group(ball_group_name)
	if candidates.size() == 0:
		return
	# If multiple candidates exist, pick the one nearest to plate (deterministic & sensible)
	var best: Node2D = null
	var best_d := 1e9
	var plate_pos := _plate.global_position if _plate != null else Vector2.ZERO
	for c in candidates:
		if c is Node2D:
			var d := absf((c as Node2D).global_position.y - plate_pos.y)
			if d < best_d:
				best_d = d
				best = c
	if best != null:
		_bind_ball(best)

func _bind_ball(b: Node2D) -> void:
	_ball = b
	_swing_scheduled = false
	_ball_prev_time = 0.0
	if b.has_signal("out_of_play"):
		if _bound_ball != b:
			b.out_of_play.connect(_on_ball_out_of_play)
			_bound_ball = b
	if debug_logs:
		print("[CpuBatter] bound ball: ", b)

func _on_ball_out_of_play() -> void:
	_swing_scheduled = false
	_ball_prev_time = 0.0
	if debug_logs:
		print("[CpuBatter] out_of_play → reset")

# -----------------------
# Aim slotting & swing probability
# -----------------------
func _apply_lr_bias(dx_at_plate: float) -> void:
	var slot := 0.0
	if dx_at_plate <= slot_left_threshold_px:
		slot = -1.0
	elif dx_at_plate >= slot_right_threshold_px:
		slot = 1.0
	else:
		slot = 0.0
	if _batter != null:
		_batter.ai_set_lr_bias(slot)

func _swing_probability(xp: float, plate_x: float, ms_to_plate: int) -> float:
	var dx := absf(xp - plate_x)

	# Soft "in-zone" curve using discipline
	var edge_px = lerp(18.0, 10.0, discipline)
	var core_px = edge_px * 0.55

	var base := 0.0
	if dx <= core_px:
		base = 0.95
	elif dx <= edge_px:
		var t = (dx - core_px) / max(0.001, (edge_px - core_px))
		var edge_will := 0.65 * (1.0 - 0.6 * discipline)  # more discipline => smaller edge will
		base = lerp(0.95, edge_will, clamp(t, 0.0, 1.0))
	else:
		base = chase_rate * (0.55 + 0.45 * (1.0 - discipline))

	# Very late recognition penalty
	if ms_to_plate < int(min_reaction_s * 1000.0 + 40.0):
		base *= 0.85

	return clamp(base, 0.0, 0.98)

# -----------------------
# Utilities
# -----------------------
func _rand_timing_jitter() -> int:
	return int(round(_rng.randf_range(-float(timing_error_ms), float(timing_error_ms))))
