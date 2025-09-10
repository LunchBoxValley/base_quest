extends Node2D
class_name Ball

signal out_of_play

@export var speed: float = 220.0
@export var max_travel: float = 200.0

var _velocity := Vector2.ZERO
var _active := false
var _start_pos := Vector2.ZERO

func _ready() -> void:
	# Hide until pitched; parent visibility will also affect the Sprite2D child.
	visible = false

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	global_position = start_global
	_start_pos = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	visible = true

func _physics_process(delta: float) -> void:
	if not _active:
		return
	global_position += _velocity * delta

	# Lifetime cap: free once we've traveled far enough (Pitcher may override max_travel)
	if global_position.distance_to(_start_pos) >= max_travel:
		_active = false
		out_of_play.emit()
		queue_free()
