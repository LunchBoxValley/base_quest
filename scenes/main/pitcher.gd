extends Node2D
class_name Pitcher

# Default to your Ball scene so the node "just works" even if you forget to wire it.
@export var ball_scene: PackedScene = preload ("res://entities/ball.tscn")
@export var pitch_speed: float = 220.0

@onready var hand: Marker2D = $Hand

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("pitch"):
		pitch()

func pitch() -> void:
	# Fallback: if someone cleared the export in the editor, re-preload and continue.
	if ball_scene == null:
		push_warning("Pitcher: 'ball_scene' was null; preloading default Ball.tscn.")
		ball_scene = preload("res://entities/ball.tscn")
	var b := ball_scene.instantiate()
	get_tree().current_scene.add_child(b)
	b.pitch_from(hand.global_position, Vector2.DOWN, pitch_speed)

func _draw() -> void:
	# Simple placeholder body so we can see the pitcher
	draw_rect(Rect2(Vector2(-4, -8), Vector2(8, 16)), Color(0.9, 0.9, 1.0), true)
