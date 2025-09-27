extends Node2D
class_name HomePlate

@export_group("Strike Zone")
@export var zone_size: Vector2 = Vector2(22, 30)     # width x height (px)
@export var zone_offset: Vector2 = Vector2(0, -6)    # relative to node
@export var plate_line_offset: float = 0.0           # y offset of the "cross plate" line
@export var debug_draw: bool = true                  # <— toggle green box in Inspector

# Track per-ball last Y and whether we've already ruled it at the plate
var _last_y := {}
var _ruled := {}

func _ready() -> void:
	add_to_group("home_plate")
	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	var plate_y := global_position.y + plate_line_offset

	for node in get_tree().get_nodes_in_group("balls"):
		if node == null or not (node is Node2D):
			continue
		var b := node as Node2D
		# Skip if ball already batted or already ruled at the plate
		if b.has_meta("batted") and b.get_meta("batted"):
			continue
		if _ruled.has(b.get_instance_id()):
			continue

		var pos := b.global_position
		var id := b.get_instance_id()
		var had := _last_y.has(id)
		var last: float = float(_last_y[id]) if had else pos.y

		# Detect crossing of the plate line from above to below (screen coords increase downward)
		if had and last < plate_y and pos.y >= plate_y:
			var zone_center := global_position + zone_offset
			var half_w := zone_size.x * 0.5
			var left_x := zone_center.x - half_w
			var right_x := zone_center.x + half_w

			if pos.x >= left_x and pos.x <= right_x:
				GameManager.call_strike()
			else:
				GameManager.call_ball()

			_ruled[id] = true
			# Pitch is over if untouched
			GameManager.end_play()

		_last_y[id] = pos.y

	# Cleanup dead ids
	var to_erase: Array = []
	for k in _last_y.keys():
		if not is_instance_id_valid(k):
			to_erase.append(k)
	for k in to_erase:
		_last_y.erase(k)
		_ruled.erase(k)

	if debug_draw:
		queue_redraw()

func _draw() -> void:
	if not debug_draw:
		return
	var zone_center := zone_offset
	var rect := Rect2(zone_center - zone_size * 0.5, zone_size)

	# translucent fill
	draw_rect(rect, Color(0.2, 1.0, 0.2, 0.12), true)
	# border
	draw_rect(rect, Color(0.2, 1.0, 0.2, 0.8), false, 1.0)

	# plate crossing line (for tuning where we “call” it)
	var y := plate_line_offset
	draw_line(Vector2(-40, y), Vector2(40, y), Color(1,1,1,0.4), 1.0, false)
