extends Node2D
class_name PitcherCatch

@export_group("Scene Paths")
@export var pitcher_path: NodePath      # optional; leave empty to auto-resolve
@export var glove_path: NodePath        # optional; leave empty to auto-find "Glove"

@export_group("Catching")
@export var catch_radius_px: float = 18.0
@export var predict_horizon_sec: float = 0.40
@export var carry_offset_px: Vector2 = Vector2(0, -4)
@export var auto_end_play: bool = true          # end play after catch
@export var require_play_active: bool = false   # safer off while tuning
@export var recatch_cooldown_sec: float = 0.30  # brief ignore window after catch

@export_group("Debug")
@export var debug_draw: bool = false
@export var debug_prints: bool = false

var _pitcher: Node2D = null
var _glove: Node2D = null
var _ball: Ball = null
var _poll_timer: Timer = null
var _cooldown_timer: Timer = null
var _cooldown_active := false

# Debug draw cache
var _last_seg_a: Vector2 = Vector2.ZERO
var _last_seg_b: Vector2 = Vector2.ZERO

func _ready() -> void:
	_resolve_pitcher_and_glove()

	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.05
	_poll_timer.one_shot = false
	add_child(_poll_timer)
	if not _poll_timer.timeout.is_connected(_tick):
		_poll_timer.timeout.connect(_tick)
	_poll_timer.start()

	_cooldown_timer = Timer.new()
	_cooldown_timer.one_shot = true
	add_child(_cooldown_timer)
	if not _cooldown_timer.timeout.is_connected(_on_cooldown_done):
		_cooldown_timer.timeout.connect(_on_cooldown_done)

	# We never glue the ball per-frame
	set_physics_process(false)

func _on_cooldown_done() -> void:
	_cooldown_active = false

func _resolve_pitcher_and_glove() -> void:
	# Pitcher
	if pitcher_path != NodePath():
		_pitcher = get_node_or_null(pitcher_path) as Node2D
	if _pitcher == null:
		var parent_nd := get_parent() as Node2D
		var self_nd := self as Node2D
		var parent_has_glove := parent_nd != null and parent_nd.get_node_or_null("Glove") != null
		var self_has_glove := self_nd != null and self_nd.get_node_or_null("Glove") != null
		if self_has_glove and not parent_has_glove:
			_pitcher = self_nd
		elif parent_has_glove:
			_pitcher = parent_nd
		else:
			_pitcher = (self_nd if self_nd != null else parent_nd)

	# Glove
	if glove_path != NodePath() and _pitcher:
		_glove = _pitcher.get_node_or_null(glove_path) as Node2D
	if _glove == null and _pitcher != null:
		_glove = _pitcher.get_node_or_null("Glove") as Node2D
	if _glove == null:
		_glove = _pitcher

func _tick() -> void:
	if _cooldown_active:
		return
	if require_play_active and not GameManager.play_active:
		return

	if _pitcher == null or _glove == null:
		_resolve_pitcher_and_glove()
		if _pitcher == null or _glove == null:
			return

	_refresh_ball()
	if not is_instance_valid(_ball):
		return

	# STRICT: only process **throws**
	if not _is_throw(_ball):
		return

	var ppos := _pitcher.global_position
	var bpos := _ball.global_position
	var v := _ball_velocity(_ball)
	var speed2 := v.length_squared()
	if speed2 < 0.0001:
		return

	# Must be APPROACHING: velocity must have component toward pitcher
	# i.e., dot((pitcher - ball), v) > 0
	if (ppos - bpos).dot(v) <= 0.0:
		return

	var pr := catch_radius_px
	var close_enough := ppos.distance_to(bpos) <= pr

	# Intercept check (closest approach within horizon)
	var intercept_ok := false
	if not close_enough:
		var r := bpos - ppos
		var tstar = - (r.dot(v)) / max(0.0001, speed2)
		tstar = clamp(tstar, 0.0, predict_horizon_sec)
		var cpos = bpos + v * tstar
		intercept_ok = ppos.distance_to(cpos) <= pr
		if debug_draw:
			_last_seg_a = to_local(bpos)
			_last_seg_b = to_local(cpos)
			queue_redraw()

	if close_enough or intercept_ok:
		_catch_and_release(_ball)

func _refresh_ball() -> void:
	if is_instance_valid(_ball):
		return
	for n in get_tree().get_nodes_in_group("balls"):
		if n is Ball:
			_ball = n
			break

func _catch_and_release(ball: Ball) -> void:
	if not is_instance_valid(ball) or _glove == null:
		return

	# 1) Snap once to glove
	ball.global_position = _glove.global_position + carry_offset_px

	# 2) Re-enable processing & zero velocity so it rests; we do NOT keep updating it
	ball.process_mode = Node.PROCESS_MODE_INHERIT
	_set_ball_velocity(ball, Vector2.ZERO)

	# 3) Clear throw intent & any fielder claim
	if ball.has_meta("delivery"):
		ball.remove_meta("delivery")
	if ball.has_meta("claimer"):
		ball.remove_meta("claimer")

	# 4) End the play (Assisted loop reset)
	if auto_end_play:
		if debug_prints: print("[PitcherCatch] end_play()")
		GameManager.end_play()

	# 5) Cooldown so we don't re-catch immediately
	_cooldown_active = true
	_cooldown_timer.start(max(0.05, recatch_cooldown_sec))
	_ball = null

	if debug_prints: print("[PitcherCatch] Caught throw to pitcher")

func _is_throw(b: Node2D) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	if b.has_method("last_delivery"):
		return String(b.last_delivery()).to_lower() == "throw"
	return b.has_meta("delivery") and String(b.get_meta("delivery")).to_lower() == "throw"

# ---------- utilities ----------
func _set_ball_velocity(b: Node2D, v: Vector2) -> void:
	if b.has_method("set_velocity"):
		b.call("set_velocity", v)
	elif b.has_method("set_linear_velocity"):
		b.call("set_linear_velocity", v)
	else:
		if b.has_method("get"):
			var curv = b.get("velocity")
			if typeof(curv) == TYPE_VECTOR2:
				b.set("velocity", v)
			else:
				curv = b.get("linear_velocity")
				if typeof(curv) == TYPE_VECTOR2:
					b.set("linear_velocity", v)

func _ball_velocity(b: Node2D) -> Vector2:
	if b and is_instance_valid(b):
		if b.has_method("get_velocity"):
			var v = b.call("get_velocity")
			if typeof(v) == TYPE_VECTOR2:
				return v
		var vv = b.get("velocity")
		if typeof(vv) == TYPE_VECTOR2: return vv
		var lv = b.get("linear_velocity")
		if typeof(lv) == TYPE_VECTOR2: return lv
	return Vector2.ZERO

# ---------- debug drawing ----------
func _draw() -> void:
	if not debug_draw:
		return
	draw_line(_last_seg_a, _last_seg_b, Color(0.2, 1.0, 0.6, 0.8), 1.0)
