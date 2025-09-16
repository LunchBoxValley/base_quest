extends CharacterBody2D
class_name Fielder

@export_group("Team / Placement")
@export var team_id: int = 1
@export var home_marker_path: NodePath        # <- new: point to a Marker2D
var _home_marker: Node2D = null
var _spawn_pos: Vector2 = Vector2.ZERO        # fallback if no marker set

@export_group("Scene Paths")
@export var field_path: NodePath              # -> FieldJudge (node named "Field")
@export var pitcher_path: NodePath            # -> Entities/Pitcher

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

# --- Node refs ---
@onready var _nav: NavigationAgent2D = $Nav
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

func _ready() -> void:
	_spawn_pos = global_position

	if home_marker_path != NodePath():
		_home_marker = get_node_or_null(home_marker_path) as Node2D

	if field_path != NodePath():
		_field = get_node_or_null(field_path)

	if pitcher_path != NodePath():
		_pitcher = get_node_or_null(pitcher_path) as Node2D

	_timer.wait_time = max(0.06, decision_interval_sec)
	_timer.one_shot = false
	_timer.timeout.connect(_on_decide)
	_timer.start()

	_enter_state(S_IDLE)

func _physics_process(delta: float) -> void:
	# Carry logic: keep ball at glove while we own it
	if _has_ball and is_instance_valid(_ball):
		_ball.global_position = _glove.global_position + carry_offset_px

	# Simple steering towards move target
	var to_target := (_move_target - global_position)
	var dist := to_target.length()
	var desired := Vector2.ZERO
	if dist > stop_radius_px:
		desired = to_target.normalized() * move_speed

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
	match _state:
		S_IDLE:
			if _acquire_ball():
				_enter_state(S_SEEK_BALL)
			else:
				_set_target(_get_home_pos())

		S_SEEK_BALL:
			if not is_instance_valid(_ball):
				if _acquire_ball():
					pass
				else:
					_enter_state(S_RETURN)
					return

			_set_target(_ball.global_position)

			# Pickup check
			if is_instance_valid(_ball) and global_position.distance_to(_ball.global_position) <= pickup_radius_px:
				_pickup_ball(_ball)
				_enter_state(S_THROW)

		S_CARRY:
			_enter_state(S_THROW)

		S_THROW:
			if not _has_ball:
				_enter_state(S_RETURN)
				return
			var target := _choose_throw_target()
			_do_throw_to(target)
			_enter_state(S_RETURN)

		S_RETURN:
			_set_target(_get_home_pos())
			if global_position.distance_to(_get_home_pos()) <= stop_radius_px + 0.5:
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
	# Future: use _nav path. v0 moves directly.

func _acquire_ball() -> bool:
	if is_instance_valid(_ball):
		return true
	var balls := get_tree().get_nodes_in_group("balls")
	if balls.size() == 0:
		return false
	for b in balls:
		var bb := b as Ball
		if bb == null:
			continue
		_ball = bb
		if _ball.has_signal("out_of_play"):
			if not _ball.is_connected("out_of_play", Callable(self, "_on_ball_out_of_play")):
				_ball.connect("out_of_play", Callable(self, "_on_ball_out_of_play"))
		return true
	return false

func _pickup_ball(ball: Ball) -> void:
	if not is_instance_valid(ball):
		return
	_ball = ball
	_ball.process_mode = Node.PROCESS_MODE_DISABLED
	_has_ball = true

func _choose_throw_target() -> Node2D:
	var candidates: Array = []
	if _field:
		var n: Node2D = null
		n = _get_from_field("first_base_path");  if n: candidates.append(n)
		n = _get_from_field("second_base_path"); if n: candidates.append(n)
		n = _get_from_field("third_base_path");  if n: candidates.append(n)
		n = _get_from_field("home_plate_path");  if n: candidates.append(n)
	if _pitcher:
		candidates.append(_pitcher)

	var best: Node2D = null
	var best_d := 1e9
	for c in candidates:
		var pos := (c as Node2D).global_position
		var d := global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = c
	return best

func _get_from_field(prop: String) -> Node2D:
	if _field == null:
		return null
	if not _field.has_method("get"):
		return null
	var np := _field.get(prop) as NodePath
	if np == null or np == NodePath():
		return null
	return _field.get_node_or_null(np) as Node2D

func _do_throw_to(target: Node2D) -> void:
	if not _has_ball or not is_instance_valid(_ball):
		return

	var dir: Vector2
	var spd: float
	var label: String

	if target == null:
		dir = Vector2.DOWN
		spd = (throw_speed_min + throw_speed_max) * 0.5
		label = "liner"
	else:
		var vec := target.global_position - global_position
		var dist := vec.length()
		if dist <= 0.001:
			dir = Vector2.DOWN
		else:
			dir = vec.normalized()
		var t = clamp(inverse_lerp(40.0, 320.0, dist), 0.0, 1.0)
		spd = lerp(throw_speed_min, throw_speed_max, t)
		label = "liner"
		if dist >= 160.0:
			label = "fly"

	_release_and_deflect(dir, spd, {"type": label})

func _release_and_deflect(dir: Vector2, spd: float, meta: Dictionary) -> void:
	_ball.process_mode = Node.PROCESS_MODE_INHERIT
	_ball.global_position = _glove.global_position + dir * 2.0
	_ball.deflect(dir, spd, meta)
	_has_ball = false
	_ball = null

func _on_ball_out_of_play() -> void:
	_has_ball = false
	_ball = null
	if _state != S_RETURN:
		_enter_state(S_RETURN)
