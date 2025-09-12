# res://scenes/main/camera_2d.gd
extends Camera2D
class_name GameCamera

@export var default_target_path: NodePath      # drag your Pitcher here (../Entities/Pitcher)
@export var follow_lerp_speed: float = 8.0

# Where to place the default target (the pitcher) on screen BEFORE a pitch.
# X ratio 0.5 = centered horizontally. Y ratio 1/3 = one third from top.
@export var default_x_ratio: float = 0.5
@export var default_y_ratio: float = 1.0 / 3.0

var _target: Node2D
var _use_offset: bool = true   # true = frame with ratios; false = center on target

func _ready() -> void:
	enabled = true
	add_to_group("game_camera")
	follow_default(true)  # snap to offset framing on startup

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
	_use_offset = false  # when following the ball, center it
	_target = node
	if snap:
		global_position = _desired_cam_pos_for(_target.global_position, false)

func _process(delta: float) -> void:
	if _target:
		var desired := _desired_cam_pos_for(_target.global_position, _use_offset)
		var t = clamp(delta * follow_lerp_speed, 0.0, 1.0)
		var nx = lerp(global_position.x, desired.x, t)
		var ny = lerp(global_position.y, desired.y, t)
		global_position = Vector2(round(nx), round(ny))  # pixel-perfect rounding

func _desired_cam_pos_for(tpos: Vector2, use_offset: bool) -> Vector2:
	if not use_offset:
		return tpos                    # center on target
	var vsize := get_viewport_rect().size
	var vcenter := vsize * 0.5
	var desired_screen := Vector2(vsize.x * default_x_ratio, vsize.y * default_y_ratio)
	# screen = (target - camera) + vcenter  => camera = target + vcenter - desired_screen
	return tpos + (vcenter - desired_screen)
