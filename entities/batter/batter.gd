# res://entities/batter.gd
extends Node2D
class_name Batter

signal hit

@export var home_plate_path: NodePath
@export var swing_window: float = 0.12
@export var sweet_spot_phase: float = 0.5
@export var sweet_width: float = 0.30
@export var hit_radius_px: float = 8.0
@export var contact_speed: float = 260.0
@export var timing_side_gain: float = 0.6
@export var spray_random: float = 0.15
@export var power_stat: float = 1.0
@export var bat_offset: Vector2 = Vector2(0, -2)

@onready var sprite: AnimatedSprite2D = $Sprite
var _plate: Node2D
var _swing_t: float = 0.0
var _did_contact: bool = false

func _ready() -> void:
	_plate = get_node_or_null(home_plate_path)
	if not InputMap.has_action("swing"):
		InputMap.add_action("swing")
		var ev := InputEventKey.new()
		ev.keycode = KEY_X
		InputMap.action_add_event("swing", ev)
	set_physics_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("swing"):
		_swing_t = swing_window
		_did_contact = false
		_play_swing_pose()

func _physics_process(delta: float) -> void:
	if _swing_t > 0.0:
		_swing_t -= delta
		if not _did_contact:
			_check_contact()
	else:
		_reset_pose()

func _contact_point() -> Vector2:
	var base := (_plate.global_position if is_instance_valid(_plate) else global_position)
	return base + bat_offset

func _check_contact() -> void:
	var p := _contact_point()
	var min_y := (_plate.global_position.y - 10.0) if is_instance_valid(_plate) else (global_position.y - 10.0)
	var max_y := (_plate.global_position.y + 6.0)  if is_instance_valid(_plate) else (global_position.y + 6.0)

	for node in get_tree().get_nodes_in_group("balls"):
		if not (node is Ball): continue
		var b := node as Ball
		var pos := b.global_position
		if pos.y >= min_y and pos.y <= max_y and pos.distance_to(p) <= hit_radius_px:
			_did_contact = true
			_on_contact(b, p)
			break

func _on_contact(ball: Ball, hitpos: Vector2) -> void:
	var phase = 1.0 - clamp(_swing_t / max(0.0001, swing_window), 0.0, 1.0)
	var offset = phase - sweet_spot_phase
	var norm = clamp(abs(offset) / max(0.0001, sweet_width), 0.0, 1.0)
	var timing_quality = 1.0 - norm

	var side_bias = clamp(offset / max(0.0001, sweet_width), -1.0, 1.0) * timing_side_gain
	var plate_x := (_plate.global_position.x if is_instance_valid(_plate) else global_position.x)
	var point_bias = clamp((hitpos.x - plate_x) / 12.0, -1.0, 1.0)
	var spray = randf_range(-spray_random, spray_random) * (1.0 - timing_quality)

	var dx = clamp(point_bias + side_bias + spray, -1.0, 1.0)
	var up = lerp(0.6, 1.0, timing_quality)
	var dir := Vector2(dx * 0.6, -up).normalized()

	var spd = contact_speed * lerp(0.7, 1.3, timing_quality) * clamp(power_stat, 0.5, 1.6)
	ball.deflect(dir, spd)
	ball.max_travel = max(ball.max_travel, 260.0 + 120.0 * timing_quality * clamp(power_stat, 0.5, 1.6))

	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(2.0, 0.12)

	hit.emit()

	# NEW: hand the ball to the FieldJudge so it can call FOUL / HR
	var judge := get_tree().get_first_node_in_group("field_judge")
	if judge and judge.has_method("track_batted_ball"):
		judge.track_batted_ball(ball)

func _play_swing_pose() -> void:
	if sprite:
		sprite.rotation = deg_to_rad(-18)

func _reset_pose() -> void:
	if sprite:
		if abs(sprite.rotation) > 0.001:
			sprite.rotation = lerp(sprite.rotation, 0.0, 0.35)
		else:
			sprite.rotation = 0.0
