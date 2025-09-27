# Catcher.gd — minimal Assisted catcher (self-healing Timer)
extends CharacterBody2D
class_name Catcher

@export_group("Placement")
@export var home_marker_path: NodePath
var _home_marker: Node2D
var _spawn_pos: Vector2 = Vector2.ZERO

@export_group("Scene Paths")
@export var field_path: NodePath        # FieldJudge (optional, used for bounds)
@export var pitcher_path: NodePath      # Entities/Pitcher (for handbacks)

@export_group("Movement")
@export var guard_radius_px: float = 18.0   # small shuffle zone around home
@export var move_speed: float = 70.0
@export var accel: float = 900.0
@export var stop_radius_px: float = 4.0

@export_group("Ball Interaction")
@export var pickup_radius_px: float = 10.0
@export var soft_pickup_extra_px: float = 6.0
@export var soft_speed_thresh: float = 40.0
@export var carry_offset_px: Vector2 = Vector2(0, -4)

@export_group("Throw")
@export var throw_speed_min: float = 240.0
@export var throw_speed_max: float = 320.0

# Nodes (resolved in _ready; no hard $ assumptions)
var _glove: Node2D = null
var _timer: Timer = null

# External
var _field: Node = null
var _pitcher: Node2D = null

# Ball state
var _ball: Ball = null
var _has_ball := false

# State
enum { S_IDLE, S_BLOCK, S_CARRY, S_THROW }
var _state := S_IDLE
var _move_target := Vector2.ZERO

func _ready() -> void:
	# Resolve placement
	if home_marker_path != NodePath():
		_home_marker = get_node_or_null(home_marker_path) as Node2D
	_spawn_pos = (_home_marker.global_position if _home_marker else global_position)

	# Resolve scene refs
	if field_path != NodePath():
		_field = get_node_or_null(field_path)
	if pitcher_path != NodePath():
		_pitcher = get_node_or_null(pitcher_path) as Node2D

	# Resolve glove (optional)
	_glove = get_node_or_null("Glove") as Node2D
	if _glove == null:
		_glove = self  # fallback so we don't crash; carries at body center

	# Resolve/create decision timer (self-healing)
	_timer = get_node_or_null("Decide") as Timer
	if _timer == null:
		_timer = Timer.new()
		_timer.name = "Decide"
		add_child(_timer)
	# Configure/attach timer
	_timer.wait_time = 0.10
	_timer.one_shot = false
	if not _timer.timeout.is_connected(_decide):
		_timer.timeout.connect(_decide)
	_timer.start()

	add_to_group("catchers")
	_enter(S_IDLE)
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	# Carry ball at glove
	if _has_ball and is_instance_valid(_ball):
		_ball.global_position = _glove.global_position + carry_offset_px

	# Small steering within guard zone
	var to_t := _move_target - global_position
	var dist := to_t.length()
	var desired := Vector2.ZERO
	if dist > stop_radius_px:
		var speed := move_speed
		# ease in close so we don’t jitter
		if dist < 14.0:
			speed = lerp(36.0, move_speed, clamp((dist - 2.0) / 12.0, 0.0, 1.0))
		desired = to_t.normalized() * speed
	var dv := desired - velocity
	var max_step := accel * delta
	if dv.length() > max_step:
		dv = dv.normalized() * max_step
	velocity += dv
	if velocity.length() < 0.01 and dist <= stop_radius_px:
		velocity = Vector2.ZERO
	move_and_slide()

func _decide() -> void:
	# Keep ball ref warm
	if (_ball == null) or not is_instance_valid(_ball):
		for n in get_tree().get_nodes_in_group("balls"):
			if n is Ball:
				_ball = n
				break

	var live := GameManager.play_active
	var is_hit := false
	if is_instance_valid(_ball) and _ball.has_method("last_delivery"):
		is_hit = String(_ball.last_delivery()).to_lower() == "hit"

	match _state:
		S_IDLE:
			# Home stance
			_set_target(_home_pos())

			# If a hit or loose ball comes near home, shuffle to block/scoop
			if is_instance_valid(_ball):
				var pr := pickup_radius_px
				if _ball_speed(_ball) <= soft_speed_thresh:
					pr += soft_pickup_extra_px
				if _near_home(_ball.global_position) and global_position.distance_to(_ball.global_position) <= max(guard_radius_px, pr + 8.0):
					_enter(S_BLOCK)

		S_BLOCK:
			if not is_instance_valid(_ball):
				_enter(S_IDLE)
				return
			# Move between home and ball, biasing toward home plate center
			var target := _mix_toward_home(_ball.global_position, 0.35)
			_set_target(_clamp_to_guard(target))

			# Scoop
			var pr2 := pickup_radius_px
			if _ball_speed(_ball) <= soft_speed_thresh:
				pr2 += soft_pickup_extra_px
			if global_position.distance_to(_ball.global_position) <= pr2:
				_pickup(_ball)
				_enter(S_THROW)

		S_CARRY:
			_enter(S_THROW)

		S_THROW:
			if not _has_ball:
				_enter(S_IDLE)
				return
			# Simple: toss back to pitcher to reset play
			var tgt := _pitcher if is_instance_valid(_pitcher) else null
			_throw_to(tgt)
			_enter(S_IDLE)

# -------- tiny helpers --------
func _enter(s: int) -> void:
	_state = s
	if s == S_IDLE:
		_set_target(_home_pos())

func _set_target(p: Vector2) -> void:
	_move_target = p

func _home_pos() -> Vector2:
	return _home_marker.global_position if _home_marker else _spawn_pos

func _near_home(p: Vector2) -> bool:
	return p.distance_to(_home_pos()) <= guard_radius_px + 36.0

func _mix_toward_home(p: Vector2, t: float) -> Vector2:
	return _home_pos().lerp(p, clamp(t, 0.0, 1.0))

func _clamp_to_guard(p: Vector2) -> Vector2:
	var h := _home_pos()
	var v := p - h
	if v.length() > guard_radius_px:
		v = v.normalized() * guard_radius_px
	return h + v

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

func _ball_speed(b: Node2D) -> float:
	return _ball_velocity(b).length()

func _pickup(b: Ball) -> void:
	if not is_instance_valid(b):
		return
	_has_ball = true
	_ball = b
	_ball.process_mode = Node.PROCESS_MODE_DISABLED
	_ball.global_position = _glove.global_position + carry_offset_px

func _throw_to(tgt: Node2D) -> void:
	if not is_instance_valid(_ball):
		return
	var dir := Vector2.UP
	var spd := throw_speed_min
	if is_instance_valid(tgt):
		var vec := tgt.global_position - global_position
		var d := vec.length()
		dir = (vec / max(d, 0.001))
		spd = lerp(throw_speed_min, throw_speed_max, clamp(inverse_lerp(20.0, 280.0, d), 0.0, 1.0))
	_ball.process_mode = Node.PROCESS_MODE_INHERIT
	_ball.global_position = _glove.global_position + dir * 2.0
	_ball.deflect(dir, spd, {"delivery":"throw","type":"liner"})
	if _ball.has_method("mark_thrown"):
		_ball.mark_thrown()
	_has_ball = false
	_ball = null
