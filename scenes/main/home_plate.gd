extends Node2D
class_name HomePlate

signal called_strike
signal called_ball

@export var zone_size := Vector2(24, 36)   # strike zone width x height (centered on this node)
@export var show_zone: bool = true         # toggle to show/hide the overlay
@export var debug_print: bool = true
@export var ball_radius_px: float = 2.0    # 4×4 ball -> radius ≈ 2 px for edge clips
@export var plate_size := Vector2(8, 8)    # reference only (sprite handles visuals now)

var _tracked: Dictionary = {}  # { Node2D: Vector2 } previous position per live ball

func _ready() -> void:
	set_physics_process(true)
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

func _physics_process(_delta: float) -> void:
	if _tracked.is_empty():
		return

	var rect := _zone_global_rect()
	var rect_bottom := rect.position.y + rect.size.y
	var rect_left := rect.position.x
	var rect_right := rect_left + rect.size.x

	# iterate over a copy so we can erase mid-loop
	for ball in _tracked.keys():
		if not is_instance_valid(ball):
			_tracked.erase(ball)
			continue

		var prev: Vector2 = _tracked[ball]
		var cur: Vector2 = ball.global_position

		var prev_in_y := (prev.y >= rect.position.y) and (prev.y <= rect_bottom)
		var cur_in_y := (cur.y >= rect.position.y) and (cur.y <= rect_bottom)

		if (not prev_in_y) and cur_in_y:
			# treat any overlap of the 4×4 ball with the zone as a strike
			var left := rect_left - ball_radius_px
			var right := rect_right + ball_radius_px
			var inside_x := (cur.x >= left) and (cur.x <= right)

			if inside_x:
				if debug_print: print("STRIKE")
				called_strike.emit()
			else:
				if debug_print: print("BALL")
				called_ball.emit()
			_tracked.erase(ball)
		else:
			_tracked[ball] = cur

func _zone_global_rect() -> Rect2:
	# centered on this node, convert to global space
	var top_left := global_position - zone_size * 0.5
	return Rect2(top_left, zone_size)

func _draw() -> void:
	if not show_zone:
		return
	# Strike zone overlay only (sprite handles plate art)
	var zone := Rect2(-zone_size * 0.5, zone_size)
	draw_rect(zone, Color(1, 1, 1, 0.08), true)
	draw_rect(zone, Color(1, 1, 1, 0.35), false)
