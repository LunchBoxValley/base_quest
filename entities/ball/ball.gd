extends Node2D
class_name Ball

signal out_of_play

@export var speed: float = 220.0
@export var max_travel: float = 200.0

var _velocity := Vector2.ZERO
var _active := false
var _start_pos := Vector2.ZERO

func _ready() -> void:
	visible = false

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	global_position = start_global
	_start_pos = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	visible = true
	queue_redraw()

func _physics_process(delta: float) -> void:
	if not _active:
		return
	global_position += _velocity * delta
	if global_position.distance_to(_start_pos) >= max_travel:
		_active = false
		out_of_play.emit()
		queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, 1.5, Color.WHITE)
