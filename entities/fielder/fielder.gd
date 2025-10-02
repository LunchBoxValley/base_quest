extends CharacterBody2D
class_name Fielder

@export_group("Team / Placement")
@export var team_id: int = 1
@export var home_marker_path: NodePath
var _home_marker: Node2D = null
var _spawn_pos: Vector2 = Vector2.ZERO

@export_group("Scene Paths")
@export var field_path: NodePath
@export var pitcher_path: NodePath

@export_group("Role")
@export var assigned_base_path: NodePath        # Set on 1B / 2B / 3B fielders
@export var is_outfielder: bool = false         # True for LF / RF

@export_group("Movement")
@export var move_speed: float = 85.0
@export var accel: float = 900.0
@export var stop_radius_px: float = 6.0

@export_group("Ball Interaction")
@export var pickup_radius_px: float = 10.0
@export var carry_offset_px: Vector2 = Vector2(0, -4)
@export var throw_speed_min: float = 240.0
@export var throw_speed_max: float = 380.0

@export_group("AI")
@export var decision_interval_sec: float = 0.15

@export_group("Pursuit")
@export var pursuit_lead_sec: float = 0.25
@export var pursuit_max_lead_px: float = 80

@export_group("Approach")
@export var approach_slow_radius_px: float = 36.0
@export var approach_min_speed: float = 42.0
@export var soft_pickup_extra_radius_px: float = 4.0
@export var soft_pickup_speed_thresh: float = 35.0

@export_group("Relay (optional)")
@export var enable_relay: bool = false
@export var deep_ball_min_dist_px: float = 180.0
@export var relay_fraction_from_base: float = 0.35
@export var relay_side_offset_px: float = 10.0

@export_group("Assisted Throwing")
@export var prefer_first_on_hit: bool = true
@export var fallback_to_pitcher: bool = true

@export_group("Catching (incoming throws)")
@export var catch_radius_px: float = 26.0
@export var graze_extra_px: float = 6.0
@export var max_catch_speed_to_fielder: float = 230.0
@export var require_approaching: bool = true
@export var approach_dot_threshold: float = 0.20
@export var catch_cooldown_sec: float = 0.12

@export_group("Catch FX")
@export var catch_puff_enabled: bool = true
@export var catch_puff_lifetime_sec: float = 0.45

@export_group("Cover Throwing")
@export var require_cover_on_base_to_throw: bool = true
@export var on_base_catch_radius_px: float = 8.0
@export var hold_near_base_offset_px: float = 18.0

@export_group("Debug")
@export var debug_prints: bool = false

# --- Node refs ---
@onready var _glove: Node2D = $Glove
@onready var _timer: Timer = $DecisionTimer

# --- External refs ---
var _field: Node = null
var _pitcher: Node2D = null

# --- Ball state ---
var _ball: Ball = null
var _has_ball: bool = false

# --- State machine ---
enum { S_IDLE, S_SEEK_BALL, S_CARRY, S_THROW, S_RETURN }
var _state: int = S_IDLE
var _move_target: Vector2 = Vector2.ZERO

# --- Cover-base micro (state) ---
var _cover_target: Node2D = null

# --- Relay micro (state) ---
var _relay_active: bool = false
var _relay_target: Vector2 = Vector2.ZERO

# --- Throw decision cache ---
var _throw_target: Node2D = null

# --- Catching cooldown ---
var _catch_cooldown_until: float = 0.0

# --- Intended throw context (base + coverer) ---
var _intend_base: Node2D = null
var _intend_coverer: Fielder = null

func _ready() -> void:
	if home_marker_path != NodePath():
		_home_marker = get_node_or_null(home_marker_path) as Node2D
	if _home_marker != null:
		_spawn_pos = _home_marker.global_position
	else:
		_spawn_pos = global_position

	if field_path != NodePath():
		_field = get_node_or_null(field_path)
	_resolve_pitcher_if_needed()

	_timer.wait_time = max(0.06, decision_interval_sec)
	_timer.one_shot = false
	if not _timer.timeout.is_connected(_on_decide):
		_timer.timeout.connect(_on_decide)
	_timer.start()

	add_to_group("fielders")
	_enter_state(S_IDLE)

	# If this fielder is permanently assigned to a base, register helpful meta.
	var base := _get_assigned_base()
	if base != null:
		base.set_meta("assigned_fielder_id", get_instance_id())

func _physics_process(delta: float) -> void:
	# Keep carried ball pinned to glove
	if _has_ball and is_instance_valid(_ball):
		_ball.global_position = _glove.global_position + carry_offset_px

	# Try to glove an incoming throw if we don't already hold a ball
	if not _has_ball:
		_try_glove_incoming_throw()

	# Movement
	var to_target := (_move_target - global_position)
	var dist := to_target.length()
	var desired_speed := move_speed

	if _state == S_SEEK_BALL:
		var pred := _move_target
		if is_instance_valid(_ball):
			pred = _predict_ball_point(_ball)
		var d_to_pred := global_position.distance_to(pred)
		if d_to_pred < approach_slow_radius_px:
			var t = clamp(d_to_pred / max(0.001, approach_slow_radius_px), 0.0, 1.0)
			desired_speed = lerp(approach_min_speed, move_speed, t)

	var desired := Vector2.ZERO
	if dist > stop_radius_px:
		desired = to_target.normalized() * desired_speed

	var dv := desired - velocity
	var max_step := accel * delta
	if dv.length() > max_step:
		dv = dv.normalized() * max_step
	velocity += dv
	if velocity.length() < 0.01 and dist <= stop_radius_px:
		velocity = Vector2.ZERO
	move_and_slide()

# -------------------- AI Core --------------------
func _on_decide() -> void:
	if (_ball == null) or (not is_instance_valid(_ball)):
		_acquire_ball()

	var live := GameManager.play_active
	var is_hit := _is_live_hit()

	match _state:
		S_IDLE:
			if live and is_hit and _acquire_ball() and _can_chase_ball(_ball) and _i_am_closest_to_ball(_ball):
				_claim_ball(_ball)
				_enter_state(S_SEEK_BALL)
			else:
				if not _relay_tick(live, is_hit):
					_cover_tick(live, is_hit)

		S_SEEK_BALL:
			if not live or _ball_is_foul(_ball):
				_release_ball_claim(_ball)
				_enter_state(S_RETURN)
				return
			if not is_instance_valid(_ball) or not _is_live_hit():
				_release_ball_claim(_ball)
				_enter_state(S_RETURN)
				return
			if not _i_am_closest_to_ball(_ball):
				_release_ball_claim(_ball)
				_enter_state(S_RETURN)
				return
			_set_target(_predict_ball_point(_ball))
			if is_instance_valid(_ball):
				var pr := pickup_radius_px
				if _ball_speed(_ball) <= soft_pickup_speed_thresh:
					pr += soft_pickup_extra_radius_px
				if global_position.distance_to(_ball.global_position) <= pr:
					_pickup_ball(_ball)
					_enter_state(S_THROW)

		S_CARRY:
			_enter_state(S_THROW)

		S_THROW:
			if not _has_ball:
				_enter_state(S_RETURN)
				return

			# Outfielders throw to the fielder covering the runner’s current/next base.
			# Infielders also use coverer logic (e.g., 3B throwing to 2B cover).
			_compute_intended_base_and_coverer()

			if require_cover_on_base_to_throw and _intend_base != null and _intend_coverer != null:
				if not _is_fielder_on_base(_intend_coverer, _intend_base, on_base_catch_radius_px):
					var hold := _hold_point_near_base(_intend_base, hold_near_base_offset_px)
					_set_target(hold)
					return

			var target_node: Node2D = null
			if _intend_coverer != null:
				target_node = _intend_coverer
			else:
				target_node = _choose_throw_target()

			if target_node == null:
				_set_target(_get_home_pos())
				return

			_do_throw_to(target_node)
			_enter_state(S_RETURN)

		S_RETURN:
			if not _relay_tick(live, is_hit):
				_cover_tick(live, is_hit)
			if not live or not is_hit:
				_cover_release_all()
				_relay_clear()
				_set_target(_get_home_pos())
			if global_position.distance_to(_get_home_pos()) <= stop_radius_px + 0.5 and (not live or not is_hit):
				_enter_state(S_IDLE)

# -------------------- Helpers --------------------
func _get_home_pos() -> Vector2:
	# If assigned to a base, “home” is the base—keeps them on the bag when idle.
	var base := _get_assigned_base()
	if base != null:
		return base.global_position
	if _home_marker != null:
		return _home_marker.global_position
	return _spawn_pos

func _get_assigned_base() -> Node2D:
	if assigned_base_path != NodePath():
		return get_node_or_null(assigned_base_path) as Node2D
	return null

func _enter_state(s: int) -> void:
	_state = s
	match _state:
		S_IDLE:
			_set_target(_get_home_pos())
		S_SEEK_BALL:
			pass
		S_CARRY:
			pass
		S_THROW:
			_compute_intended_base_and_coverer()
		S_RETURN:
			_set_target(_get_home_pos())

func _set_target(p: Vector2) -> void:
	_move_target = p

func _resolve_field() -> Node:
	if _field and is_instance_valid(_field):
		return _field
	var g := get_tree().get_first_node_in_group("field_judge")
	if g:
		_field = g
	return _field

func _resolve_pitcher_if_needed() -> void:
	if _pitcher == null and pitcher_path != NodePath():
		_pitcher = get_node_or_null(pitcher_path) as Node2D
	if _pitcher == null:
		var g := get_tree().get_first_node_in_group("pitcher")
		if g == null:
			g = get_tree().get_first_node_in_group("pitchers")
		_pitcher = g as Node2D
	if _pitcher == null:
		var root := get_tree().get_current_scene()
		if root:
			_pitcher = root.get_node_or_null(NodePath("Pitcher")) as Node2D

# --- CLOSEST-FIELDER selection ---
func _i_am_closest_to_ball(b: Node2D, slack_px: float = 6.0) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	var my_d := global_position.distance_to(b.global_position)
	for n in get_tree().get_nodes_in_group("fielders"):
		if n == self or not (n is Fielder):
			continue
		var other := n as Fielder
		var od := other.global_position.distance_to(b.global_position)
		if od + slack_px < my_d:
			return false
	return true

func _current_chaser(b: Node2D) -> Fielder:
	if b == null or not is_instance_valid(b):
		return null
	var best: Fielder = null
	var best_d := 1e9
	for n in get_tree().get_nodes_in_group("fielders"):
		if not (n is Fielder):
			continue
		var f := n as Fielder
		var d := f.global_position.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			best = f
	return best

# --- Predictive pursuit helpers ---
func _ball_velocity(b: Node2D) -> Vector2:
	if b == null or not is_instance_valid(b):
		return Vector2.ZERO
	if b.has_method("get_velocity"):
		var v = b.call("get_velocity")
		if typeof(v) == TYPE_VECTOR2:
			return v
	var vv = b.get("velocity")
	if typeof(vv) == TYPE_VECTOR2:
		return vv
	var lv = b.get("linear_velocity")
	if typeof(lv) == TYPE_VECTOR2:
		return lv
	return Vector2.ZERO

func _ball_speed(b: Node2D) -> float:
	return _ball_velocity(b).length()

func _predict_ball_point(b: Node2D) -> Vector2:
	if b == null or not is_instance_valid(b):
		return global_position
	var p := b.global_position
	var v := _ball_velocity(b)
	var lead = clamp(pursuit_lead_sec, 0.0, 0.5)
	var pred = p + v * lead
	if pursuit_max_lead_px > 0.0:
		var offset = pred - p
		if offset.length() > pursuit_max_lead_px:
			pred = p + offset.normalized() * pursuit_max_lead_px
	var judge := _resolve_field()
	if judge and judge.has_method("get"):
		var wb = judge.get("world_bounds")
		if typeof(wb) == TYPE_RECT2:
			pred.x = clamp(pred.x, wb.position.x, wb.position.x + wb.size.x)
			pred.y = clamp(pred.y, wb.position.y, wb.position.y + wb.size.y)
	return pred

# --- single-claimer system to prevent dog-piles ---
func _can_chase_ball(b: Node) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	if not (b.has_method("last_delivery") and String(b.last_delivery()).to_lower() == "hit"):
		return false
	var claim = b.get_meta("claimer") if b.has_meta("claimer") else null
	return claim == null or int(claim) == get_instance_id()

func _claim_ball(b: Node) -> void:
	if b and is_instance_valid(b):
		b.set_meta("claimer", get_instance_id())
		if b.has_signal("out_of_play") and not b.is_connected("out_of_play", Callable(self, "_on_claimed_ball_out")):
			b.connect("out_of_play", Callable(self, "_on_claimed_ball_out"))

func _release_ball_claim(b: Node) -> void:
	if b and is_instance_valid(b):
		if b.has_meta("claimer") and int(b.get_meta("claimer")) == get_instance_id():
			b.remove_meta("claimer")
		if b.has_signal("out_of_play") and b.is_connected("out_of_play", Callable(self, "_on_claimed_ball_out")):
			b.disconnect("out_of_play", Callable(self, "_on_claimed_ball_out"))

func _on_claimed_ball_out() -> void:
	_release_ball_claim(_ball)
	_ball = null
	if _state != S_RETURN:
		_enter_state(S_RETURN)

func _acquire_ball() -> bool:
	if is_instance_valid(_ball):
		return true
	var best: Ball = null
	var best_d := 1e9
	var pos := global_position
	for n in get_tree().get_nodes_in_group("balls"):
		var bb := n as Ball
		if bb == null:
			continue
		if not _can_chase_ball(bb):
			continue
		var d := pos.distance_to(bb.global_position)
		if d < best_d:
			best_d = d
			best = bb
	if best == null:
		return false
	_ball = best
	if _ball.has_signal("out_of_play"):
		if not _ball.is_connected("out_of_play", Callable(self, "_on_ball_out_of_play")):
			_ball.connect("out_of_play", Callable(self, "_on_ball_out_of_play"))
	return true

func _pickup_ball(ball: Ball) -> void:
	if not is_instance_valid(ball):
		return
	_has_ball = true
	_ball = ball
	_cover_release_all()
	_relay_clear()
	_release_ball_claim(ball)
	_ball.process_mode = Node.PROCESS_MODE_DISABLED
	_ball.global_position = _glove.global_position
	_emit_catch_puff(_glove.global_position)
	_compute_intended_base_and_coverer()

# --- Assigned-base + cover system ---
func _compute_intended_base_and_coverer() -> void:
	_intend_base = _determine_runner_base()
	_intend_coverer = null
	if _intend_base != null:
		_intend_coverer = _resolve_coverer_for_base(_intend_base)

func _determine_runner_base() -> Node2D:
	var root := get_tree().get_current_scene()
	if root == null:
		return _get_base1()
	var runners := get_tree().get_nodes_in_group("runners")
	var best_base: Node2D = null
	var best_d := 1e9
	if runners.size() > 0:
		for r in runners:
			if r is Runner:
				var rr := r as Runner
				var cur_idx := -1
				if rr.has_method("get_current_path_index"):
					cur_idx = int(rr.get_current_path_index())
				var next_idx := -1
				if rr.has_method("get_next_path_index"):
					next_idx = int(rr.get_next_path_index())
				if cur_idx >= 0 and cur_idx < rr.path.size():
					var bcur := root.get_node_or_null(rr.path[cur_idx]) as Node2D
					if bcur:
						var ref := global_position
						if is_instance_valid(_ball):
							ref = _ball.global_position
						var d1 := ref.distance_to(bcur.global_position)
						if d1 < best_d:
							best_d = d1
							best_base = bcur
				if next_idx >= 0 and next_idx < rr.path.size():
					var bnext := root.get_node_or_null(rr.path[next_idx]) as Node2D
					if bnext:
						var ref2 := global_position
						if is_instance_valid(_ball):
							ref2 = _ball.global_position
						var d2 := ref2.distance_to(bnext.global_position)
						if d2 < best_d:
							best_d = d2
							best_base = bnext
			elif r.has_method("next_base_path"):
				var np = r.call("next_base_path")
				if typeof(np) == TYPE_NODE_PATH:
					var bb := root.get_node_or_null(np) as Node2D
					if bb:
						var ref3 := global_position
						if is_instance_valid(_ball):
							ref3 = _ball.global_position
						var d3 := ref3.distance_to(bb.global_position)
						if d3 < best_d:
							best_d = d3
							best_base = bb
	if best_base != null:
		return best_base

	var b1 := _get_base1()
	if b1 != null and (_is_live_hit() or prefer_first_on_hit):
		return b1

	_resolve_pitcher_if_needed()
	if fallback_to_pitcher and _pitcher and is_instance_valid(_pitcher):
		return _pitcher

	return b1

func _resolve_coverer_for_base(base: Node2D) -> Fielder:
	if base == null:
		return null
	if base.has_meta("coverer"):
		var id_val = base.get_meta("coverer")
		for n in get_tree().get_nodes_in_group("fielders"):
			if n is Fielder:
				var f := n as Fielder
				if int(id_val) == f.get_instance_id():
					return f
	# Prefer permanently assigned fielder if registered
	if base.has_meta("assigned_fielder_id"):
		var aid := int(base.get_meta("assigned_fielder_id"))
		for n in get_tree().get_nodes_in_group("fielders"):
			if n is Fielder and int((n as Fielder).get_instance_id()) == aid:
				return n as Fielder
	# Otherwise nearest infielder
	var best: Fielder = null
	var best_d := 1e9
	for n in get_tree().get_nodes_in_group("fielders"):
		if not (n is Fielder):
			continue
		var f := n as Fielder
		if not f._is_infielder_strict():
			continue
		var d := f.global_position.distance_to(base.global_position)
		if d < best_d:
			best_d = d
			best = f
	return best

func _is_fielder_on_base(f: Fielder, base: Node2D, radius_px: float) -> bool:
	if f == null or base == null:
		return false
	return f.global_position.distance_to(base.global_position) <= max(0.0, radius_px)

func _hold_point_near_base(base: Node2D, offset_px: float) -> Vector2:
	if base == null:
		return global_position
	var from := global_position - base.global_position
	if from.length() < 0.001:
		from = Vector2(0, -1)
	return base.global_position + from.normalized() * max(0.0, offset_px)

# --- Legacy fallback if no coverer found ---
func _choose_throw_target() -> Node2D:
	if _intend_coverer != null:
		return _intend_coverer
	var base1 := _get_base1()
	if base1 != null and (_is_live_hit() or prefer_first_on_hit):
		return base1
	_resolve_pitcher_if_needed()
	if fallback_to_pitcher and _pitcher and is_instance_valid(_pitcher):
		return _pitcher
	return base1

func _get_base1() -> Node2D:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var b1 := root.get_node_or_null(NodePath("Entities/Base1")) as Node2D
	if b1 == null:
		b1 = root.get_node_or_null(NodePath("Base1")) as Node2D
	return b1

# ------------ THROW ------------
func _do_throw_to(target: Node2D) -> void:
	if not is_instance_valid(_ball) or not _has_ball:
		return

	_resolve_pitcher_if_needed()

	var final_target: Node2D = null
	if target != null and is_instance_valid(target):
		final_target = target
	else:
		if _pitcher != null and is_instance_valid(_pitcher):
			final_target = _pitcher
		else:
			final_target = _get_base1()

	if final_target == null or not is_instance_valid(final_target):
		if debug_prints: print("[Fielder] ABORT throw: no valid target")
		return

	var aim_pos := final_target.global_position
	var glove := _get_glove_of(final_target)
	if glove != null:
		aim_pos = glove.global_position

	var vec := aim_pos - global_position
	var dist := vec.length()
	var dir := Vector2.DOWN
	if dist > 0.0001:
		dir = vec / dist

	var is_pitcher := (final_target == _pitcher) \
		|| final_target.is_in_group("pitcher") \
		|| final_target.is_in_group("pitchers") \
		|| String(final_target.name).to_lower() == "pitcher"

	var spd: float
	if is_pitcher:
		var t_norm = clamp(inverse_lerp(40.0, 220.0, dist), 0.0, 1.0)
		var desired_t = lerp(0.30, 0.38, t_norm)
		spd = clamp(dist / max(0.001, desired_t), 110.0, 200.0)
	else:
		var t = clamp(inverse_lerp(40.0, 320.0, dist), 0.0, 1.0)
		spd = lerp(throw_speed_min, throw_speed_max, t)

	if debug_prints:
		var label := String(final_target.name)
		print("[Fielder] Throw -> ", label, " aim=", aim_pos, " dist=", dist, " spd=", spd)

	var meta := {
		"delivery": "throw",
		"type": "liner",
		"arc": ( "flat" if is_pitcher else "normal" ),
		"randomness": (0.0 if is_pitcher else 0.15),
		"spin": (0.0 if is_pitcher else 0.1),
		"assist": true
	}
	if is_pitcher:
		meta["target"] = "pitcher"

	_ball.process_mode = Node.PROCESS_MODE_INHERIT
	_ball.global_position = _glove.global_position + dir * 2.0
	_ball.set_meta("thrown_by", "fielder")

	if _ball.has_method("deflect"):
		_ball.deflect(dir, spd, meta)
	else:
		if _ball.has_method("set_velocity"):
			_ball.call("set_velocity", dir * spd)
		elif _ball.has_method("set_linear_velocity"):
			_ball.call("set_linear_velocity", dir * spd)
		elif _ball.has_method("set"):
			if typeof(_ball.get("velocity")) == TYPE_VECTOR2:
				_ball.set("velocity", dir * spd)
			elif typeof(_ball.get("linear_velocity")) == TYPE_VECTOR2:
				_ball.set("linear_velocity", dir * spd)
		_ball.set_meta("delivery", "throw")
		_ball.set_meta("type", "liner")
		_ball.set_meta("arc", "flat")

	if _ball.has_method("mark_thrown"):
		_ball.mark_thrown()

	_cover_release_all()
	_relay_clear()
	_has_ball = false
	_ball = null
	_throw_target = null
	_intend_base = null
	_intend_coverer = null

func _get_glove_of(target: Node2D) -> Node2D:
	if target == null:
		return null
	var glove := target.get_node_or_null("Glove") as Node2D
	if glove != null:
		return glove
	return null

func _on_ball_out_of_play() -> void:
	_has_ball = false
	_cover_release_all()
	_relay_clear()
	_release_ball_claim(_ball)
	_ball = null
	if _state != S_RETURN:
		_enter_state(S_RETURN)

# ---------------- Catch incoming throws ----------------
func _try_glove_incoming_throw() -> void:
	var now := Time.get_ticks_msec() * 0.001
	if now < _catch_cooldown_until:
		return

	var best: Node2D = null
	var best_score := -1e9
	var gpos := _glove.global_position

	for n in get_tree().get_nodes_in_group("balls"):
		var b := n as Node2D
		if b == null:
			continue
		if b == _ball:
			continue

		var delivery := _delivery_of(b).to_lower()
		if delivery != "throw":
			continue
		if b.has_meta("caught_by"):
			continue

		var bpos := b.global_position
		var to_glove := gpos - bpos
		var dist := to_glove.length()
		var vel := _get_ball_velocity(b)
		var speed := vel.length()
		var toward := 0.0
		if speed > 0.001 and dist > 0.001:
			var dir_ball := vel / speed
			var dir_to_glove := to_glove / dist
			toward = dir_ball.dot(dir_to_glove)

		var score := -dist + toward * 15.0
		if score > best_score:
			best_score = score
			best = b

	if best == null:
		return

	var g := _glove.global_position
	var bp := best.global_position
	var delta := g - bp
	var d := delta.length()
	var max_d := catch_radius_px + graze_extra_px
	if d > max_d:
		return

	var v := _get_ball_velocity(best)
	var s := v.length()
	if s > max_catch_speed_to_fielder:
		return

	if require_approaching and s > 0.001 and d > 4.0:
		var dir_ball := v / s
		var dir_to_glove := delta / d
		var dot := dir_ball.dot(dir_to_glove)
		if dot < approach_dot_threshold:
			return

	_receive_ball_from_throw(best)
	_catch_cooldown_until = now + catch_cooldown_sec

func _receive_ball_from_throw(bb: Node2D) -> void:
	_set_ball_velocity(bb, Vector2.ZERO)
	if bb.has_method("clear_spin"):
		bb.call("clear_spin")
	bb.global_position = _glove.global_position
	if bb is Node:
		(bb as Node).set_meta("delivery_override", "caught")
		(bb as Node).set_meta("caught_by", "fielder")
	_has_ball = true
	_ball = bb as Ball
	if _ball and _ball.is_in_group("balls"):
		_ball.remove_from_group("balls")
	if _ball:
		_ball.process_mode = Node.PROCESS_MODE_DISABLED

	_emit_catch_puff(_glove.global_position)
	_compute_intended_base_and_coverer()
	_enter_state(S_THROW)

# ---------------- Cover-Base ----------------
func _cover_release_all() -> void:
	if _cover_target and is_instance_valid(_cover_target):
		if _cover_target.has_meta("coverer") and int(_cover_target.get_meta("coverer")) == get_instance_id():
			_cover_target.remove_meta("coverer")
	_cover_target = null

func _get_bases() -> Array:
	var bases: Array = []
	var root := get_tree().get_current_scene()
	if root:
		var b1 := root.get_node_or_null(NodePath("Base1")) as Node2D
		var b2 := root.get_node_or_null(NodePath("Base2")) as Node2D
		var b3 := root.get_node_or_null(NodePath("Base3")) as Node2D
		if b1 == null: b1 = root.get_node_or_null(NodePath("Entities/Base1")) as Node2D
		if b2 == null: b2 = root.get_node_or_null(NodePath("Entities/Base2")) as Node2D
		if b3 == null: b3 = root.get_node_or_null(NodePath("Entities/Base3")) as Node2D
		if b1: bases.append(b1)
		if b2: bases.append(b2)
		if b3: bases.append(b3)
	return bases

func _is_infielder() -> bool:
	# If explicitly marked outfielder, it’s not an infielder.
	if is_outfielder:
		return false
	# If assigned to a base, definitely an infielder.
	if assigned_base_path != NodePath():
		return true
	# Fallback: proximity heuristic
	return _is_infielder_proximity()

func _is_infielder_proximity() -> bool:
	var bases := _get_bases()
	if _home_marker == null or bases.is_empty():
		return true
	for b in bases:
		if _home_marker.global_position.distance_to((b as Node2D).global_position) <= 80.0:
			return true
	return false

func _is_infielder_strict() -> bool:
	if is_outfielder:
		return false
	if assigned_base_path != NodePath():
		return true
	return _is_infielder_proximity()

func _cover_tick(live: bool, is_hit: bool) -> void:
	# Assigned-base fielders: default to standing on their bag whenever they’re not the chaser.
	var my_base := _get_assigned_base()
	if my_base != null:
		if not live or not is_hit:
			# Between plays: be on the bag
			_cover_target = my_base
			_cover_target.set_meta("coverer", get_instance_id())
			_set_target(my_base.global_position)
			return
		# During a live hit
		if _ball and _i_am_closest_to_ball(_ball):
			# You’re the chaser; release bag temporarily
			_cover_release_all()
			return
		# Otherwise, claim and stand on your base
		_cover_target = my_base
		_cover_target.set_meta("coverer", get_instance_id())
		_set_target(my_base.global_position)
		return

	# Non-assigned infielders: take nearest uncovered base.
	if not live or not is_hit or not _is_infielder():
		_cover_release_all()
		if not _relay_active:
			_set_target(_get_home_pos())
		return
	if _ball and _i_am_closest_to_ball(_ball):
		_cover_release_all()
		return

	var my_pos := global_position
	var best: Node2D = null
	var best_d := 1e9
	for b in _get_bases():
		var base := b as Node2D
		if base == null:
			continue
		# Don’t steal a base from its assigned fielder unless no one is covering
		if base.has_meta("assigned_fielder_id"):
			var aid := int(base.get_meta("assigned_fielder_id"))
			# If the assigned fielder exists and is not me, prefer they cover it.
			if aid != get_instance_id():
				# If already covered by anyone else, skip.
				var claimA = base.get_meta("coverer") if base.has_meta("coverer") else null
				if claimA != null:
					continue
		# Respect current coverer claim
		var claim = base.get_meta("coverer") if base.has_meta("coverer") else null
		if claim != null and int(claim) != get_instance_id():
			continue
		var d := my_pos.distance_to(base.global_position)
		if d < best_d:
			best_d = d
			best = base

	if best != null:
		if _cover_target and _cover_target != best:
			_cover_release_all()
		_cover_target = best
		_cover_target.set_meta("coverer", get_instance_id())
		_set_target(_cover_target.global_position)
	else:
		_cover_release_all()
		if not _relay_active:
			_set_target(_get_home_pos())

# ---------------- Relay (optional) ----------------
func _relay_clear() -> void:
	_relay_active = false
	_relay_target = _get_home_pos()

func _relay_tick(live: bool, is_hit: bool) -> bool:
	if not enable_relay or not live or not is_hit or _ball == null or not is_instance_valid(_ball):
		_relay_clear()
		return false

	var chaser := _current_chaser(_ball)
	if chaser == null:
		_relay_clear()
		return false
	if chaser._is_infielder_strict():
		_relay_clear()
		return false
	if not _is_infielder_strict():
		_relay_clear()
		return false
	if chaser == self:
		_relay_clear()
		return false

	var bases := _get_bases()
	if bases.is_empty():
		_relay_clear()
		return false

	var home_guess := global_position
	var b1 := (bases[0] as Node2D) if bases.size() >= 1 else null
	var b3 := (bases[2] as Node2D) if bases.size() >= 3 else null
	if b1 and b3:
		home_guess = (b1.global_position + b3.global_position) * 0.5
	var ball_dist_home := _ball.global_position.distance_to(home_guess)
	if ball_dist_home < deep_ball_min_dist_px:
		_relay_clear()
		return false

	var plate_x := home_guess.x
	var target_base: Node2D = null
	var root := get_tree().get_current_scene()
	var base1 := root.get_node_or_null(NodePath("Base1")) as Node2D
	var base2 := root.get_node_or_null(NodePath("Base2")) as Node2D
	if base1 == null: base1 = root.get_node_or_null(NodePath("Entities/Base1")) as Node2D
	if base2 == null: base2 = root.get_node_or_null(NodePath("Entities/Base2")) as Node2D

	if _ball.global_position.x >= plate_x and base1:
		target_base = base1
	elif base2:
		target_base = base2
	else:
		_relay_clear()
		return false

	var a := target_base.global_position
	var b := chaser.global_position
	var frac = clamp(relay_fraction_from_base, 0.1, 0.9)
	var p := a.lerp(b, frac)

	var dir := (b - a).normalized()
	var perp := Vector2(-dir.y, dir.x)
	p += perp * relay_side_offset_px

	var judge := _resolve_field()
	if judge and judge.has_method("get"):
		var wb = judge.get("world_bounds")
		if typeof(wb) == TYPE_RECT2:
			p.x = clamp(p.x, wb.position.x, wb.position.x + wb.size.x)
			p.y = clamp(p.y, wb.position.y, wb.position.y + wb.size.y)

	_relay_active = true
	_relay_target = p
	_set_target(_relay_target)
	return true

# ---------------- tiny utility ----------------
func _is_live_hit() -> bool:
	if not is_instance_valid(_ball):
		return false
	if not GameManager.play_active:
		return false
	if _ball.has_method("last_delivery"):
		return String(_ball.last_delivery()).to_lower() == "hit"
	return _ball.has_meta("batted") and bool(_ball.get_meta("batted"))

func _ball_is_foul(b: Node) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	if b.has_method("is_foul"):
		return bool(b.call("is_foul"))
	if b.has_meta("foul"):
		return bool(b.get_meta("foul"))
	return false

# ---------------- Catch FX (CPU particles, inline) ----------------
func _emit_catch_puff(at: Vector2) -> void:
	if not catch_puff_enabled:
		return
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.local_coords = true
	p.lifetime = max(0.2, catch_puff_lifetime_sec)
	p.amount = 8
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINT
	p.position = to_local(at)

	p.initial_velocity_min = 10.0
	p.initial_velocity_max = 16.0
	p.direction = Vector2(0, -1)
	p.spread = 20.0
	p.gravity = Vector2(0, -18)

	var grad := Gradient.new()
	grad.add_point(0.0, Color(0.92, 0.92, 0.92, 0.50))
	grad.add_point(0.6, Color(0.88, 0.88, 0.88, 0.25))
	grad.add_point(1.0, Color(0.85, 0.85, 0.85, 0.0))
	p.color_ramp = grad

	add_child(p)
	p.emitting = true

	var t := get_tree().create_timer(p.lifetime + 0.1, true, true)
	await t.timeout
	if is_instance_valid(p):
		p.queue_free()

# ---------------- shared helpers for catching ----------------
func _delivery_of(b: Node2D) -> String:
	if b.has_meta("delivery_override"):
		return String(b.get_meta("delivery_override"))
	if b.has_meta("delivery"):
		return String(b.get_meta("delivery"))
	if b.has_method("last_delivery"):
		return String(b.call("last_delivery"))
	return "unknown"

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

func _set_ball_velocity(b: Node2D, v: Vector2) -> void:
	if b.has_method("set_velocity"):
		b.call("set_velocity", v)
	elif b.has_method("set_linear_velocity"):
		b.call("set_linear_velocity", v)
	elif b.has_method("set"):
		if typeof(b.get("velocity")) == TYPE_VECTOR2:
			b.set("velocity", v)
		elif typeof(b.get("linear_velocity")) == TYPE_VECTOR2:
			b.set("linear_velocity", v)
