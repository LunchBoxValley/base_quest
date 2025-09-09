
extends Node2D
class_name Ball

@export var speed: float = 220.0

var _velocity: Vector2 = Vector2.ZERO
var _active: bool = false

func _ready() -> void:
	visible = false

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	global_position = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	visible = true
	queue_redraw()

func _physics_process(delta: float) -> void:
	if _active:
		global_position += _velocity * delta
		# Simple lifetime guard: free once off the bottom of the screen (+padding)
		if global_position.y > get_viewport_rect().size.y + 8:
			queue_free()

func _draw() -> void:
	# 3px-ish "ball"
	draw_circle(Vector2.ZERO, 1.5, Color.WHITE)
