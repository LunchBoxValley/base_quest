extends Camera2D
class_name GameCamera

# Drag your Pitcher node here in the editor.
@export var default_target_path: NodePath
@export var follow_lerp_speed: float = 8.0

var _target: Node2D

func _ready() -> void:
	enabled = true                # <-- Godot 4.4.x correct activation flag
	add_to_group("game_camera")
	follow_default()

func follow_default() -> void:
	if default_target_path != NodePath():
		var d := get_node_or_null(default_target_path)
		if d is Node2D:
			_target = d

func follow_target(node: Node2D) -> void:
	_target = node

func _process(delta: float) -> void:
	if _target:
		global_position = global_position.lerp(
			_target.global_position,
			clamp(delta * follow_lerp_speed, 0.0, 1.0)
		)
