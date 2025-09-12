# res://scenes/main/field_judge.gd
extends Node2D
class_name FieldJudge

signal foul_ball
signal home_run

@export_group("Layout")
@export var home_plate_path: NodePath                    # drag your HomePlate
@export var left_foul_pole: Vector2 = Vector2(48, 16)    # tweak to taste
@export var right_foul_pole: Vector2 = Vector2(272, 16)
@export var outfield_wall_y: float = 16.0                # y at the wall (top-ish)
@export var foul_margin_px: float = 0.0                  # leniency; >0 widens fair

@export_group("World Bounds (camera/kill)")
@export var world_bounds: Rect2 = Rect2(-48, -32, 416, 256)
@export var draw_debug: bool = true

var _plate: Node2D
var _ball: Node2D = null
var _tracking := false

func _ready() -> void:
	_plate = get_node_or_null(home_plate_path)
	add_to_group("field_judge")
	set_physics_process(true)
	queue_redraw()

func get_world_bounds() -> Rect2:
	return world_bounds

func track_batted_ball(ball: Node2D) -> void:
	_ball = ball
	_tracking = is_instance_valid(_ball)
	if _tracking and _ball.has_signal("out_of_play"):
		_ball.out_of_play.connect(func():
			_tracking = false
			_ball = null
		, CONNECT_ONE_SHOT)

func _physics_process(_delta: float) -> void:
	if not _tracking or not is_instance_valid(_ball) or _plate == null:
		return

	var p := _plate.global_position
	var pos := _ball.global_position

	# Camera limits safety: if ball leaves world bounds, stop tracking
	if not world_bounds.has_point(pos):
		_end_tracking()
		return

	# Compute the x-coordinates of the left/right foul lines at this y
	var xl := _line_x_at_y(p, left_foul_pole, pos.y)
	var xr := _line_x_at_y(p, right_foul_pole, pos.y)
	if xl > xr:
		var t := xl; xl = xr; xr = t

	xl -= foul_margin_px
	xr += foul_margin_px

	# Home run: crossed wall y while between the foul lines
	if pos.y <= outfield_wall_y and pos.x >= xl and pos.x <= xr:
		emit_signal("home_run")
		_end_play()
		return

	# Foul: outside the fair wedge above the plate
	if pos.x < xl or pos.x > xr:
		emit_signal("foul_ball")
		_end_play()
		return

func _end_play() -> void:
	# Let camera drift back via GameCamera.follow_default()
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("follow_default"):
		cam.follow_default()
	_end_tracking()

func _end_tracking() -> void:
	_tracking = false
	_ball = null

func _line_x_at_y(a: Vector2, b: Vector2, y: float) -> float:
	# linear interpolation along a→b for a given y (screen y grows down)
	var dy := (a.y - b.y)
	if absf(dy) < 0.0001:
		return a.x
	var t := (a.y - y) / dy
	return a.x + (b.x - a.x) * t

func _draw() -> void:
	if not draw_debug or _plate == null:
		return
	var p := _plate.global_position
	draw_line(to_local(p), to_local(left_foul_pole), Color(1,0.9,0.3,0.7), 1.0, false)
	draw_line(to_local(p), to_local(right_foul_pole), Color(1,0.9,0.3,0.7), 1.0, false)
	# Wall line
	draw_line(Vector2(world_bounds.position.x, outfield_wall_y) - global_position,
			  Vector2(world_bounds.position.x + world_bounds.size.x, outfield_wall_y) - global_position,
			  Color(0.3,1,0.5,0.6), 1.0, false)
	# World bounds
	draw_rect(Rect2(world_bounds.position - global_position, world_bounds.size), Color(1,1,1,0.12), false)
