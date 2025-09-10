# res://scenes/main/camera_2d.gd
extends Camera2D
class_name GameCamera

@export var default_target_path: NodePath
@export var follow_lerp_speed: float = 8.0

var _target: Node2D

func _ready() -> void:
	enabled = true
	add_to_group("game_camera")
	_pick_default_target()
	if _target:
		# Snap on boot so we don't stare at (0, 0)
		global_position = _target.global_position

func follow_default() -> void:
	_pick_default_target()

func follow_target(node: Node2D) -> void:
	_target = node

func _process(delta: float) -> void:
	if _target:
		var p := global_position.lerp(_target.global_position, clamp(delta * follow_lerp_speed, 0.0, 1.0))
		global_position = Vector2(round(p.x), round(p.y)) # pixel-perfect rounding

func _pick_default_target() -> void:
	_target = null
	if default_target_path != NodePath():
		var d := get_node_or_null(default_target_path)
		if d is Node2D:
			_target = d
			return
	# Fallback: first node in group "pitcher"
	var pitchers := get_tree().get_nodes_in_group("pitcher")
	if pitchers.size() > 0 and pitchers[0] is Node2D:
		_target = pitchers[0]
