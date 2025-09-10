# res://scenes/main/home_plate.gd
extends Node2D
class_name HomePlate

signal called_strike
signal called_ball

@export var zone_size := Vector2(24, 36)  # strike zone width x height
@export var plate_w: float = 12.0
@export var plate_h: float = 8.0
@export var debug_print: bool = true      # turn off if the console gets noisy

# Track live balls -> previous position (so we call once when they enter the band)
var _tracked: Dictionary = {}  # { Node2D: Vector2 }

func _ready() -> void:
	set_physics_process(true)  # ensure _physics_process runs in 4.4.1
	queue_redraw()

func register_ball(ball: Node2D) -> void:
	if ball == null:
		return
	_tracked[ball] = ball.global_position
	if debug_print:
		print("[HomePlate] Registered ball ", ball.get_instance_id(), " at ", _tracked[ball])
	ball.tree_exited.connect(func ():
		_tracked.erase(ball)
		if debug_print:
			print("[HomePlate] Ball removed (tree_exited)")
	)

func _physics_process(delta: float) -> void:
	if _tracked.is_empty():
		return

	var rect := _zone_global_rect()
	var rect_bottom := rect.position.y + rect.size.y
	var rect_right := rect.position.x + rect.size.x

	# Iterate over a copy so we can erase during the loop
	for ball in _tracked.keys():
		if not is_instance_valid(ball):
			_tracked.erase(ball)
			continue

		var prev: Vector2 = _tracked[ball]
		var cur: Vector2 = ball.global_position

		# Detect first entry into the vertical band of the strike zone
		var prev_in_y := (prev.y >= rect.position.y) and (prev.y <= rect_bottom)
		var cur_in_y := (cur.y >= rect.position.y) and (cur.y <= rect_bottom)

		if (not prev_in_y) and cur_in_y:
			var inside_x := (cur.x >= rect.position.x) and (cur.x <= rect_right)
			if inside_x:
				if debug_print: print("STRIKE")
				called_strike.emit()
			else:
				if debug_print: print("BALL")
				called_ball.emit()
			_tracked.erase(ball)  # judge once per pitch
		else:
			_tracked[ball] = cur

func _draw() -> void:
	# Strike zone (light fill + outline)
	var zone := Rect2(-zone_size * 0.5, zone_size)
	draw_rect(zone, Color(1, 1, 1, 0.08), true)
	draw_rect(zone, Color(1, 1, 1, 0.35), false)

	# Home plate (simple pentagon)
	var hw := plate_w * 0.5
	var pts := PackedVector2Array([
		Vector2(-hw, -plate_h), Vector2(hw, -plate_h),
		Vector2(hw, 0), Vector2(0, plate_h * 0.6), Vector2(-hw, 0)
	])
	draw_colored_polygon(pts, Color(1, 1, 1))

func _zone_global_rect() -> Rect2:
	var top_left := global_position - zone_size * 0.5
	return Rect2(top_left, zone_size)
