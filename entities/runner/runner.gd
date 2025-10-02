extends Node2D
class_name Runner

signal reached_base(base_idx: int)
signal forced_out(base_idx: int)
signal scored()

# ---------- Movement ----------
@export_group("Movement")
@export var speed: float = 80.0
@export var acceleration: float = 600.0
@export var snap_dist: float = 6.0

# ---------- Pathing & Rules ----------
# Path order should be: [Home, 1B, 2B, 3B, Home]
@export_group("Pathing & Rules")
@export var path: Array[NodePath] = []
@export var is_forced: bool = true                # batter-runner usually forced off Home to 1B
@export var forced_until_index: int = 1           # force advance while current target index < this

# ---------- AI Heuristics (Advance/Retreat) ----------
@export_group("AI Heuristics")
@export var decision_interval_sec: float = 0.12
@export var base_radius_px: float = 12.0
@export var go_threshold_ms: float = 250.0         # beat ball by >= this → GO
@export var retreat_threshold_ms: float = -120.0   # ball beats runner by <= this → RETREAT
@export var commit_stick_ms: float = 180.0         # hysteresis: stick to a choice for this long

# Ball / Fielder guesses (px/s)
@export var ai_throw_speed_guess: float = 300.0
@export var ai_fielder_run_speed_guess: float = 110.0
@export var ai_ball_pickup_penalty_ms: float = 120.0

# ---------- Human Control (optional) ----------
@export_group("Human Control")
@export var human_control_enabled: bool = true
@export var input_advance_action: String = "runner_advance"
@export var input_retreat_action: String = "runner_retreat"

# ---------- FX ----------
@export_group("FX")
@export var smoke_fx: PackedScene        # assign SmokePuff.tscn

# ---------- Internal state ----------
enum { S_ON_BASE, S_ADVANCING, S_RETREATING, S_OUT }
var _state: int = S_ON_BASE

var _idx := 0                     # current target path index (where we are heading)
var _vel := Vector2.ZERO
var _alive := true
var _commit_until_ms: int = 0     # sticky window end time (ms since startup)

var _decision_timer: Timer = null

# Fair-ball auto-run guard (prevents double-starts if multiple signals fire)
var _auto_break_armed: bool = true

func _ready() -> void:
	add_to_group("runners")
	set_physics_process(true)
	_setup_inputs()

	# Decision timer
	_decision_timer = Timer.new()
	_decision_timer.one_shot = false
	_decision_timer.wait_time = max(0.06, decision_interval_sec)
	add_child(_decision_timer)
	_decision_timer.timeout.connect(_on_decide)
	_decision_timer.start()

	# Hook global play/judge if available
	_connect_game_manager()
	_connect_field_judge()

func id() -> int:
	return int(get_instance_id())

func begin_at_path_index(i: int) -> void:
	_idx = clamp(i, 0, path.size() - 1)
	var n := _target_node()
	if n:
		global_position = n.global_position
		_puff(global_position) # tiny poof at spawn
	_state = S_ON_BASE
	_auto_break_armed = true

# Advance target to next path node (used for forced steps or when we decide to go)
func commit_to_next() -> void:
	if _idx < path.size() - 1:
		_idx += 1

func get_next_path_index() -> int:
	if path.is_empty():
		return 0
	return min(_idx + 1, path.size() - 1)

func next_base_path() -> NodePath:
	if path.is_empty():
		return NodePath()
	return path[get_next_path_index()]

# ---------------- Physics ----------------
func _physics_process(delta: float) -> void:
	if not _alive:
		return

	_process_human_input()

	var tgt := _target_node()
	if tgt == null:
		return

	var goal := tgt.global_position
	var to_vec := goal - global_position
	var dist := to_vec.length()
	var dir := Vector2.ZERO
	if dist > 0.001:
		dir = to_vec / dist

	_vel = _vel.move_toward(dir * speed, acceleration * delta)
	global_position += _vel * delta

	# Arrive if within snap or within base radius
	if dist <= max(snap_dist, speed * delta) or dist <= base_radius_px:
		_arrive_at_base(tgt)

# ---------------- Decisions ----------------
func _on_decide() -> void:
	if not _alive or path.is_empty():
		return

	# Respect forced progression up to a target index (e.g., force to 1B from Home)
	if is_forced and _idx < forced_until_index:
		if _state != S_ADVANCING:
			_state = S_ADVANCING
			commit_to_next()
			_commit_sticky()
		return

	var next_i := get_next_path_index()
	var next_base := _node_from_path_index(next_i)
	var prev_base := _node_from_path_index(max(0, _idx - 1))
	var now_ms := Time.get_ticks_msec()

	# If we're standing "on" base, evaluate advancing to next
	if _state == S_ON_BASE and next_base != null:
		if now_ms >= _commit_until_ms:
			var act := _should_go_to(next_base)
			if act == 1:
				_state = S_ADVANCING
				commit_to_next()
				_commit_sticky()
				return
		return

	# If we’re advancing, consider a retreat (only if sticky window expired)
	if _state == S_ADVANCING and next_base != null:
		if now_ms >= _commit_until_ms:
			var act2 := _should_go_to(next_base) # positive margin favors continuing
			if act2 == -1:
				# Retreat back toward previous index
				_idx = max(0, _idx - 1)
				_state = S_RETREATING
				_commit_sticky()
				return
		return

	# If we’re retreating, consider flipping forward again (rare but coherent)
	if _state == S_RETREATING and prev_base != null:
		if now_ms >= _commit_until_ms:
			var act3 := _should_go_to(prev_base)  # here, "go" means margin favors previous base
			if act3 == 1:
				_idx = min(_idx + 1, path.size() - 1)
				_state = S_ADVANCING
				_commit_sticky()
				return

# returns: 1 = GO, 0 = HOLD, -1 = RETREAT (relative to the given base)
func _should_go_to(base: Node2D) -> int:
	if base == null:
		return 0
	var rt := _time_runner_to(base)
	var bt := _time_ball_to(base)
	var margin := bt - rt  # positive = runner arrives before ball

	if margin >= go_threshold_ms:
		return 1
	if margin <= retreat_threshold_ms:
		return -1
	return 0

func _commit_sticky() -> void:
	_commit_until_ms = Time.get_ticks_msec() + int(commit_stick_ms)

# ---------------- Arrival / Outcomes ----------------
func _arrive_at_base(base_node: Node2D) -> void:
	# Ask the Base to judge force/tag (your Base script may do this)
	var is_out := false
	if base_node and base_node.has_method("runner_arrived"):
		is_out = base_node.runner_arrived(self)

	var base_idx := _idx

	if is_out:
		forced_out.emit(base_idx)
		_alive = false
		_state = S_OUT
		if base_idx == 1:
			_puff(global_position) # poof on force at 1B for flavor
		queue_free()
		return

	reached_base.emit(base_idx)

	# Scored if this is the last node (Home at end of path)
	if _idx >= path.size() - 1:
		scored.emit()
		_alive = false
		_state = S_OUT
		_puff(global_position) # optional poof on scoring
		queue_free()
		return

	# At base, we are idling (unless forced rule applies in next tick)
	_state = S_ON_BASE

	# Optional: once we’ve reached 1B, stop forcing beyond it (classic arcade rule)
	if base_idx >= forced_until_index:
		is_forced = false
	_auto_break_armed = true

# ---------------- Time Estimates ----------------
func _time_runner_to(base: Node2D) -> float:
	var d := global_position.distance_to(base.global_position)
	return (d / max(0.001, speed)) * 1000.0

func _time_ball_to(base: Node2D) -> float:
	var best_ms := INF

	# 1) If there is an active Ball in play, estimate from its current motion
	var best_ball := _nearest_active_ball()
	if best_ball != null:
		var v := _get_ball_velocity(best_ball)
		var spd = max(0.001, v.length())
		var d := best_ball.global_position.distance_to(base.global_position)
		var t_ms = (d / spd) * 1000.0
		# If the ball is moving very slowly, assume pickup + throw
		if spd < 40.0:
			t_ms = ai_ball_pickup_penalty_ms + (d / max(1.0, ai_throw_speed_guess)) * 1000.0
		best_ms = min(best_ms, t_ms)
	else:
		# 2) No visible ball (likely being held). Assume nearest fielder can throw immediately.
		var f := _nearest_fielder_to(base.global_position)
		if f != null:
			var src := f.global_position
			var d2 := src.distance_to(base.global_position)
			var t2 = (d2 / max(1.0, ai_throw_speed_guess)) * 1000.0
			best_ms = min(best_ms, t2)
		# If no fielders found, leave as INF (green light)

	return best_ms

func _nearest_active_ball() -> Node2D:
	var best: Node2D = null
	var best_d := 1e12
	for n in get_tree().get_nodes_in_group("balls"):
		var b := n as Node2D
		if b == null:
			continue
		var d := global_position.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			best = b
	return best

func _nearest_fielder_to(p: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := 1e12
	for n in get_tree().get_nodes_in_group("fielders"):
		var f := n as Node2D
		if f == null:
			continue
		var d := p.distance_to(f.global_position)
		if d < best_d:
			best_d = d
			best = f
	return best

# ---------------- Human Input ----------------
func _setup_inputs() -> void:
	if not human_control_enabled:
		return
	# Lazily create actions if missing
	if not InputMap.has_action(input_advance_action):
		InputMap.add_action(input_advance_action)
		var ev_up := InputEventKey.new()
		ev_up.keycode = KEY_E     # default: E to advance
		InputMap.action_add_event(input_advance_action, ev_up)
	if not InputMap.has_action(input_retreat_action):
		InputMap.add_action(input_retreat_action)
		var ev_down := InputEventKey.new()
		ev_down.keycode = KEY_Q   # default: Q to retreat
		InputMap.action_add_event(input_retreat_action, ev_down)

func _process_human_input() -> void:
	if not human_control_enabled or not _alive:
		return
	var now_ms := Time.get_ticks_msec()
	var can_commit := (now_ms >= _commit_until_ms)

	if can_commit and Input.is_action_just_pressed(input_advance_action):
		# Commit toward next base (if exists)
		if _idx < path.size() - 1:
			_state = S_ADVANCING
			commit_to_next()
			_commit_sticky()
			return

	if can_commit and Input.is_action_just_pressed(input_retreat_action):
		# Commit toward previous base (if exists)
		if _idx > 0:
			_state = S_RETREATING
			_idx = max(0, _idx - 1)
			_commit_sticky()
			return

# ---------------- Fair/Foul Integration ----------------
# If the play goes live on a fair hit, batter MUST break for first.
func _on_play_started_fair() -> void:
	if not _alive or path.size() < 2:
		return
	# Arm only once per play
	if not _auto_break_armed:
		return
	_auto_break_armed = false

	# Force until 1B (index 1). If we're still at Home (index 0), break now.
	is_forced = true
	forced_until_index = 1
	if _idx < 1:
		_state = S_ADVANCING
		commit_to_next()   # move target to 1B
		_commit_sticky()

# If foul, cancel the forced break and return to Home.
func _on_ruled_foul() -> void:
	if not _alive or path.is_empty():
		return
	is_forced = false
	forced_until_index = 0
	_state = S_ON_BASE
	_idx = 0
	_vel = Vector2.ZERO
	_auto_break_armed = true

# Optional: on home run, you could force all the way around
func _on_home_run() -> void:
	# Uncomment if you want auto-trot:
	# is_forced = true
	# forced_until_index = path.size() - 1
	pass

func _connect_game_manager() -> void:
	# If your GameManager exposes play_state_changed(active: bool), wire it.
	var gm := get_node_or_null("/root/GameManager")
	if gm and gm.has_signal("play_state_changed"):
		gm.connect("play_state_changed", Callable(self, "_on_play_state_changed"))

func _on_play_state_changed(active: bool) -> void:
	# We only auto-break when play becomes active (fair hit in play).
	if active:
		_on_play_started_fair()

func _connect_field_judge() -> void:
	var judge := get_tree().get_first_node_in_group("field_judge")
	if judge:
		if judge.has_signal("foul_ball") and not judge.is_connected("foul_ball", Callable(self, "_on_ruled_foul")):
			judge.connect("foul_ball", Callable(self, "_on_ruled_foul"))
		if judge.has_signal("home_run") and not judge.is_connected("home_run", Callable(self, "_on_home_run")):
			judge.connect("home_run", Callable(self, "_on_home_run"))

# ---------------- Helpers ----------------
func _target_node() -> Node2D:
	return _node_from_path_index(_idx)

func _node_from_path_index(i: int) -> Node2D:
	if i < 0 or i >= path.size():
		return null
	return get_node_or_null(path[i]) as Node2D

func _get_ball_velocity(b: Node2D) -> Vector2:
	if b.has_method("get_velocity"):
		var v = b.call("get_velocity")
		if typeof(v) == TYPE_VECTOR2:
			return v
	var v1 = b.get("velocity")
	if typeof(v1) == TYPE_VECTOR2:
		return v1
	var v2 = b.get("linear_velocity")
	if typeof(v2) == TYPE_VECTOR2:
		return v2
	return Vector2.ZERO

# ---------------- FX ----------------
func _puff(pos: Vector2) -> void:
	if smoke_fx:
		var fx := smoke_fx.instantiate()
		var root := get_tree().get_current_scene()
		if root:
			root.add_child(fx)
			fx.global_position = pos
