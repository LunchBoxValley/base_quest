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

@export_group("Debug")
@export var debug_prints: bool = false

# --- Node refs ---
@onready var _glove: Node2D = $Glove
@onready var _timer: Timer = $DecisionTimer
@onready var _base_sensor: Area2D = $BaseSensor  # <-- NEW: Area2D at fielder’s feet

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

# --- Base overlap tracking (for force calls) ---
var _overlapping_bases: Array[Area2D] = []   # stores BaseZone Areas

func _ready() -> void:
	# Resolve refs
	if home_marker_path != NodePath():
		_home_marker = get_node_or_null(home_marker_path) as Node2D
	if _home_marker != null:
		_spawn_pos = _home_marker.global_position
	else:
		_spawn_pos = global_position

	if field_path != NodePath():
		_field = get_node_or_null(field_path)
	_resolve_pitcher_if_needed()

	# Decision loop
	_timer.wait_time = max(0.06, decision_interval_sec)
	_timer.one_shot = false
	if not _timer.timeout.is_connected(_on_decide):
		_timer.timeout.connect(_on_decide)
	_timer.start()

	# BaseSensor hookups (NEW)
	if is_instance_valid(_base_sensor):
		if not _base_sensor.area_entered.is_connected(_on_base_sensor_entered):
			_base_sensor.area_entered.connect(_on_base_sensor_entered)
		if not _base_sensor.area_exited.is_connected(_on_base_sensor_exited):
			_base_sensor.area_exited.connect(_on_base_sensor_exited)

	add_to_group("fielders")
	_enter_state(S_IDLE)

func _physics_process(delta: float) -> void:
	# Carry logic: keep ball at glove while we own it
	if _has_ball and is_instance_valid(_ball):
		_ball.global_position = _glove.global_position + carry_offset_px
		# If standing on a base while holding the ball, stamp control time (NEW)
		if _overlapping_bases.size() > 0:
			_register_ball_on_any_overlapped_base()

	# Simple steering toward move target, with arrival braking during S_SEEK_BALL
	var to_target := (_move_target - global_position)
	var dist := to_target.length()
	var desired_speed := move_speed

	if _state == S_SEEK_BALL:
		var pred := _predict_ball_point(_ball) if is_instance_valid(_ball) else _move_target
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
			if not live:
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

			# Pickup check (with gentle scoop)
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
			var target := _throw_target if _throw_target != null else _choose_throw_target()
			_do_throw_to(target)
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
	if _home_marker != null:
		return _home_marker.global_position
	return _spawn_pos

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
			pass
		S_RETURN:
			_set_target(_get_home_pos())

func _set_target(p: Vector2) -> void:
	_move_target = p
	# (optional: NavigationAgent2D hookup later)

# --- FieldJudge lookup (optional) ---
func _resolve_field() -> Node:
	if _field and is_instance_valid(_field):
		return _field
	var g := get_tree().get_first_node_in_group("field_judge")
	if g:
		_field = g
	return _field

# --- Pitcher resolution ---
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

# --- single-claimer system ---
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
	_throw_target = _choose_throw_target()
	# If we’re already on a base when we pick up, stamp control time immediately (NEW)
	_register_ball_on_any_overlapped_base()

func _choose_throw_target() -> Node2D:
	var base1 := _get_base1()
	if prefer_first_on_hit and _is_live_hit() and base1:
		return base1
	_resolve_pitcher_if_needed()
	if fallback_to_pitcher and _pitcher and is_instance_valid(_pitcher):
		return _pitcher
	return base1

func _get_base1() -> Node2D:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	return root.get_node_or_null(NodePath("Base1")) as Node2D

func _do_throw_to(target: Node2D) -> void:
	if not is_instance_valid(_ball) or not _has_ball:
		return

	_resolve_pitcher_if_needed()

	var final_target: Node2D = null
	if target != null and is_instance_valid(target):
		final_target = target
	else:
		final_target = (_pitcher if (_pitcher != null and is_instance_valid(_pitcher)) else _get_base1())

	if final_target == null or not is_instance_valid(final_target):
		if debug_prints: print("[Fielder] ABORT throw: no valid target")
		return

	var is_pitcher := (final_target == _pitcher) \
		|| final_target.is_in_group("pitcher") \
		|| final_target.is_in_group("pitchers") \
		|| String(final_target.name).to_lower() == "pitcher"

	var aim_pos := final_target.global_position
	var glove := final_target.get_node_or_null("Glove") as Node2D
	if glove != null:
		aim_pos = glove.global_position

	var vec := aim_pos - global_position
	var dist := vec.length()
	var dir := Vector2.DOWN
	if dist > 0.0001:
		dir = vec / dist

	var spd: float
	if is_pitcher:
		var t_norm = clamp(inverse_lerp(40.0, 220.0, dist), 0.0, 1.0)
		var desired_t = lerp(0.30, 0.38, t_norm)
		spd = clamp(dist / max(0.001, desired_t), 110.0, 200.0)
	else:
		var t = clamp(inverse_lerp(40.0, 320.0, dist), 0.0, 1.0)
		spd = lerp(throw_speed_min, throw_speed_max, t)

	if debug_prints:
		print("[Fielder] Throw -> ", ( "Pitcher" if is_pitcher else String(final_target.name)),
			" aim=", aim_pos, " dist=", dist, " spd=", spd, " dir=", dir)

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

func _on_ball_out_of_play() -> void:
	_has_ball = false
	_cover_release_all()
	_relay_clear()
	_release_ball_claim(_ball)
	_ball = null
	if _state != S_RETURN:
		_enter_state(S_RETURN)

# ---------------- Base sensing (NEW) ----------------
func _on_base_sensor_entered(a: Area2D) -> void:
	if a.is_in_group("BaseZone"):
		_overlapping_bases.append(a)
		if _has_ball:
			_register_ball_on_any_overlapped_base()

func _on_base_sensor_exited(a: Area2D) -> void:
	_overlapping_bases.erase(a)

func _register_ball_on_any_overlapped_base() -> void:
	for a in _overlapping_bases:
		var base := a.get_parent()
		if base and base.has_method("ball_controlled_on_bag"):
			base.ball_controlled_on_bag()  # stamps time on the base

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
		if b1: bases.append(b1)
		if b2: bases.append(b2)
		if b3: bases.append(b3)
	return bases

func _is_infielder() -> bool:
	var bases := _get_bases()
	if _home_marker == null or bases.is_empty():
		return true
	for b in bases:
		if _home_marker.global_position.distance_to((b as Node2D).global_position) <= 80.0:
			return true
	return false

func _cover_tick(live: bool, is_hit: bool) -> void:
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
	if chaser._is_infielder():
		_relay_clear()
		return false
	if not _is_infielder():
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
