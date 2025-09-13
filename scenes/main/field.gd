extends Node2D
class_name FieldJudge

signal foul_ball
signal home_run

@export_group("Scene Paths")
@export var home_plate_path: NodePath
@export var first_base_path: NodePath
@export var second_base_path: NodePath
@export var third_base_path: NodePath

@export_group("Layout Size (global px)")
@export var desired_field_size: Vector2 = Vector2(640, 360)

@export_group("Layout Margins (px)")
@export var top_margin_px: float = 20.0
@export var side_margin_px: float = 16.0
@export var bottom_margin_px: float = 36.0

@export_group("Diamond / Foul Geometry")
@export var base_side_px: float = 140.0        # equal spacing: Home→1st and 1st→2nd etc.
@export var foul_margin_px: float = 0.0        # leniency inside wedge

@export_group("Debug & Bounds")
@export var draw_debug: bool = true
@export var world_bounds: Rect2 = Rect2(-96, -64, 512, 384)  # set in reconfigure_layout()
@export var outfield_wall_y: float = 16.0                    # set in reconfigure_layout()
@export var left_foul_pole: Vector2 = Vector2(48, 16)        # set in reconfigure_layout()
@export var right_foul_pole: Vector2 = Vector2(272, 16)      # set in reconfigure_layout()

var _plate: Node2D
var _ball: Node2D = null
var _tracking := false

func _ready() -> void:
	_plate = get_node_or_null(home_plate_path)
	add_to_group("field_judge")
	reconfigure_layout()
	set_physics_process(true)
	queue_redraw()

func get_world_bounds() -> Rect2:
	return world_bounds

# ----------------------------------------------------------
# Auto compute camera bounds, HR line, foul poles, and place bases
# ----------------------------------------------------------
func reconfigure_layout() -> void:
	if _plate == null:
		push_warning("[FieldJudge] home_plate_path is not set; cannot reconfigure.")
		return

	var home := _plate.global_position
	var w := desired_field_size.x
	var h := desired_field_size.y

	# Keep Home where it is; put the larger world rect around it,
	# with Home sitting bottom_margin_px above the world bottom.
	var left := home.x - w * 0.5
	var top  := home.y - (h - bottom_margin_px)
	world_bounds = Rect2(left, top, w, h)

	# HR line near the top, and foul poles at that line with side margins
	outfield_wall_y = world_bounds.position.y + top_margin_px
	left_foul_pole  = Vector2(world_bounds.position.x + side_margin_px, outfield_wall_y)
	right_foul_pole = Vector2(world_bounds.position.x + world_bounds.size.x - side_margin_px, outfield_wall_y)

	# Unit directions along each foul ray (Home→3rd on the left, Home→1st on the right)
	var dir_left  := (left_foul_pole  - home).normalized()
	var dir_right := (right_foul_pole - home).normalized()
	var bisector  := (dir_left + dir_right)
	if bisector.length() > 0.0001:
		bisector = bisector.normalized()
	else:
		bisector = Vector2(0, -1) # fallback straight up

	# Place bases: 1st & 3rd at base_side_px along each ray; 2nd at √2 * base_side_px along bisector
	var first_pos  := home + dir_right * base_side_px
	var third_pos  := home + dir_left  * base_side_px
	var second_pos := home + bisector  * base_side_px * sqrt(2.0)

	var first  := get_node_or_null(first_base_path)  as Node2D
	var second := get_node_or_null(second_base_path) as Node2D
	var third  := get_node_or_null(third_base_path)  as Node2D
	if first:  first.global_position  = first_pos
	if second: second.global_position = second_pos
	if third:  third.global_position  = third_pos

# ----------------------------------------------------------
# Ball tracking and calls (fair / foul / HR)
# ----------------------------------------------------------
func track_batted_ball(ball: Node2D) -> void:
	_ball = ball
	_tracking = is_instance_valid(_ball)
	if _tracking and _ball.has_signal("out_of_play"):
		_ball.out_of_play.connect(func():
			_tracking = false
			_ball = null
		)

func _physics_process(_delta: float) -> void:
	if not _tracking or not is_instance_valid(_ball) or _plate == null:
		return

	var p := _plate.global_position
	var pos := _ball.global_position

	# stop if ball leaves the world (safety)
	if not world_bounds.has_point(pos):
		_end_tracking()
		return

	# X positions where each foul line sits at this Y
	var xl := _line_x_at_y(p, left_foul_pole, pos.y)
	var xr := _line_x_at_y(p, right_foul_pole, pos.y)
	if xl > xr:
		var t := xl; xl = xr; xr = t

	xl -= foul_margin_px
	xr += foul_margin_px

	# Home run: crosses the wall while between the foul lines
	if pos.y <= outfield_wall_y and pos.x >= xl and pos.x <= xr:
		home_run.emit()
		_end_play()
		return

	# Foul: outside the fair wedge
	if pos.x < xl or pos.x > xr:
		foul_ball.emit()
		_end_play()
		return

func _end_play() -> void:
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("follow_default"):
		cam.follow_default()
	_end_tracking()

func _end_tracking() -> void:
	_tracking = false
	_ball = null

func _line_x_at_y(a: Vector2, b: Vector2, y: float) -> float:
	var dy := (a.y - b.y)
	if absf(dy) < 0.0001:
		return a.x
	var t := (a.y - y) / dy
	return a.x + (b.x - a.x) * t

func _draw() -> void:
	if not draw_debug or _plate == null:
		return
	var home := _plate.global_position

	# Foul lines
	draw_line(to_local(home), to_local(left_foul_pole),  Color(1,0.9,0.3,0.7), 1.0, false)
	draw_line(to_local(home), to_local(right_foul_pole), Color(1,0.9,0.3,0.7), 1.0, false)

	# HR line
	var wl := Vector2(world_bounds.position.x, outfield_wall_y)
	var wr := Vector2(world_bounds.position.x + world_bounds.size.x, outfield_wall_y)
	draw_line(to_local(wl), to_local(wr), Color(0.3,1,0.5,0.6), 1.0, false)

	# Bounds
	draw_rect(Rect2(to_local(world_bounds.position), world_bounds.size), Color(1,1,1,0.12), false)

	# Diamond (Home→1st→2nd→3rd→Home)
	var first  := get_node_or_null(first_base_path)  as Node2D
	var second := get_node_or_null(second_base_path) as Node2D
	var third  := get_node_or_null(third_base_path)  as Node2D
	if first and second and third:
		var H := to_local(home)
		var F := to_local(first.global_position)
		var S := to_local(second.global_position)
		var T := to_local(third.global_position)
		draw_line(H, F, Color(1,1,1,0.6), 1.0, false)
		draw_line(F, S, Color(1,1,1,0.6), 1.0, false)
		draw_line(S, T, Color(1,1,1,0.6), 1.0, false)
		draw_line(T, H, Color(1,1,1,0.6), 1.0, false)
		draw_circle(F, 3.0, Color(0.8,1,0.8,0.8))
		draw_circle(S, 3.0, Color(0.8,0.8,1,0.8))
		draw_circle(T, 3.0, Color(1,0.8,0.8,0.8))
