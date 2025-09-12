# res://scenes/main/camera_2d.gd
extends Camera2D
class_name GameCamera

@export var default_target_path: NodePath      # usually ../Entities/Pitcher
@export var follow_lerp_speed: float = 10.0

# Pre-pitch framing: place pitcher at 1/3 from top, centered X
@export var default_x_ratio: float = 0.5
@export var default_y_ratio: float = 1.0 / 3.0

var _target: Node2D
var _use_offset: bool = true   # true = offset framing (pitcher), false = center (ball)

# Tiny camera kick (microshake) for juice
var _kick_offset := Vector2.ZERO
var _kick_time := 0.0
var _kick_len := 0.0

func _ready() -> void:
	enabled = true
	add_to_group("game_camera")
	follow_default(true)  # snap to pitcher offset on boot

func follow_default(snap: bool = false) -> void:
	_use_offset = true
	if default_target_path != NodePath():
		var d := get_node_or_null(default_target_path)
		if d is Node2D:
			_target = d
			if snap:
				global_position = _desired_cam_pos_for(_target.global_position, true)

func follow_target(node: Node2D, snap: bool = false) -> void:
	if node == null:
		return
	_use_offset = false  # center on ball while pitching
	_target = node
	if snap:
		global_position = _desired_cam_pos_for(_target.global_position, false)

func kick(strength_px := 2.0, duration := 0.12) -> void:
	_kick_offset = Vector2(randf() * 2.0 - 1.0, 1.0).normalized() * strength_px
	_kick_time = duration
	_kick_len = duration

func _process(delta: float) -> void:
	if _target == null:
		return
	var desired := _desired_cam_pos_for(_target.global_position, _use_offset)
	if _kick_time > 0.0:
		_kick_time -= delta
		var k = clamp(_kick_time / max(_kick_len, 0.00001), 0.0, 1.0) # ease-out
		desired += _kick_offset * k

	var t = clamp(delta * follow_lerp_speed, 0.0, 1.0)
	var nx = lerp(global_position.x, desired.x, t)
	var ny = lerp(global_position.y, desired.y, t)
	global_position = Vector2(round(nx), round(ny))  # pixel-perfect

func _desired_cam_pos_for(tpos: Vector2, use_offset: bool) -> Vector2:
	if not use_offset:
		return tpos  # center on target
	var vsize := get_viewport_rect().size
	var vcenter := vsize * 0.5
	var desired_screen := Vector2(vsize.x * default_x_ratio, vsize.y * default_y_ratio)
	# screen = (target - camera) + vcenter  => camera = target + vcenter - desired_screen
	return tpos + (vcenter - desired_screen)
