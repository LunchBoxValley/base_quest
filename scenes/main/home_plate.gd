extends Node2D

@export var zone_size := Vector2(24, 36)   # strike zone rectangle
@export var plate_w: float = 12.0
@export var plate_h: float = 8.0

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	# Strike zone (light filled rect + outline)
	var zone := Rect2(-zone_size * 0.5, zone_size)
	draw_rect(zone, Color(1, 1, 1, 0.08), true)
	draw_rect(zone, Color(1, 1, 1, 0.35), false)

	# Home plate (pentagon)
	var hw := plate_w * 0.5
	var pts := PackedVector2Array([
		Vector2(-hw, -plate_h),   # top-left
		Vector2(hw, -plate_h),    # top-right
		Vector2(hw, 0),           # right
		Vector2(0, plate_h * 0.6),# bottom tip
		Vector2(-hw, 0)           # left
	])
	draw_colored_polygon(pts, Color(1, 1, 1))
