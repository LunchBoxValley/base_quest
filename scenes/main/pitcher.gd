extends Node2D
class_name Pitcher

@export var ball_scene: PackedScene
@export var pitch_speed: float = 220.0
@onready var hand: Marker2D = $Hand

func _ready() -> void:
	assert(ball_scene, "Assign Ball.tscn to 'ball_scene' on the Pitcher node.")
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("pitch"):
		pitch()

func pitch() -> void:
	var b := ball_scene.instantiate()
	get_tree().current_scene.add_child(b)
	b.pitch_from(hand.global_position, Vector2.DOWN, pitch_speed)

func _draw() -> void:
	# Simple placeholder body: 8×16 rectangle
	draw_rect(Rect2(Vector2(-4, -8), Vector2(8, 16)), Color(0.9, 0.9, 1.0), true)
