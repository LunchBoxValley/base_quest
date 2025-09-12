# res://scenes/main/home_plate.gd
extends Node2D
class_name HomePlate

signal called_strike
signal called_ball

@export_group("Strike Zone")
@export var zone_width_px: int = 24 : set = _set_zone_width
@export var zone_height_px: int = 36 : set = _set_zone_height
@export var zone_offset_px: Vector2 = Vector2(0, 0) : set = _set_zone_offset
@export var show_zone: bool = true : set = _set_show_zone

@export var consider_ball_radius: bool = true
@export var ball_radius_px: float = 2.0    # 4×4 ball → ~2 px
@export var extra_edge_px: float = 0.0     # extra leniency

@export_group("Juice")
@export var flash_time := 0.08             # zone flash on call

@export_group("Debug")
@export var debug_print: bool = true

var _tracked: Dictionary = {}   # { Node2D: Vector2 }
var _flash_t := 0.0

func _ready() -> void:
	set_physics_process(true)
	set_process(true)
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
	var rect_top := rect.position.y
	var rect_bottom := rect_top + rect.size.y
	var rect_left := rect.position.x
	var rect_right := rect_left + rect.size.x

	var margin = (ball_radius_px if consider_ball_radius else 0.0) + max(extra_edge_px, 0.0)
	var left_with_margin = rect_left - margin
	var right_with_margin = rect_right + margin

	for ball in _tracked.keys():
		if not is_instance_valid(ball):
			_tracked.erase(ball)
			continue

		var prev: Vector2 = _tracked[ball]
		var cur: Vector2 = ball.global_position

		var prev_in_y := (prev.y >= rect_top) and (prev.y <= rect_bottom)
		var cur_in_y := (cur.y >= rect_top) and (cur.y <= rect_bottom)

		if (not prev_in_y) and cur_in_y:
			var inside_x = (cur.x >= left_with_margin) and (cur.x <= right_with_margin)
			_flash_call()
			if inside_x:
				if debug_print: print("STRIKE")
				called_strike.emit()
			else:
				if debug_print: print("BALL")
				called_ball.emit()
			_tracked.erase(ball)
		else:
			_tracked[ball] = cur

func _process(delta: float) -> void:
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			queue_redraw()

func _flash_call() -> void:
	_flash_t = flash_time
	queue_redraw()
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(2.0, 0.10)

# --- Helpers ---
func _zone_local_rect() -> Rect2:
	var size := Vector2(max(1, zone_width_px), max(1, zone_height_px))
	var top_left := -size * 0.5 + zone_offset_px
	return Rect2(top_left, size)

func _zone_global_rect() -> Rect2:
	var r := _zone_local_rect()
	return Rect2(global_position + r.position, r.size)

# --- Inspector setters ---
func _set_zone_width(v: int) -> void:
	zone_width_px = max(1, v); queue_redraw()

func _set_zone_height(v: int) -> void:
	zone_height_px = max(1, v); queue_redraw()

func _set_zone_offset(v: Vector2) -> void:
	zone_offset_px = v; queue_redraw()

func _set_show_zone(v: bool) -> void:
	show_zone = v; queue_redraw()

# --- Draw (overlay only; plate art is a Sprite2D child) ---
func _draw() -> void:
	if not show_zone:
		return
	var r := _zone_local_rect()
	var a := 0.18 if _flash_t > 0.0 else 0.08   # <-- fixed ternary
	draw_rect(r, Color(1,1,1,a), true)
	draw_rect(r, Color(1,1,1,0.35), false)
