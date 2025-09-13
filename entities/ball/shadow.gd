extends Node2D
class_name BallShadow

@export var base_radius_px: float = 4.0
@export var color: Color = Color(0, 0, 0, 0.5)

var _radius: float = 4.0
var _alpha: float = 0.5

func set_shape(radius_px: float, alpha: float) -> void:
	_radius = max(0.1, radius_px)
	_alpha = clamp(alpha, 0.0, 1.0)
	queue_redraw()

func _draw() -> void:
	var c := Color(color.r, color.g, color.b, _alpha)
	draw_circle(Vector2.ZERO, _radius, c)
