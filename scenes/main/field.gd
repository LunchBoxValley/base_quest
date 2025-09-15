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
@export var base_side_px: float = 140.0
@export var foul_margin_px: float = 0.0

@export_group("Debug & Bounds")
@export var draw_debug: bool = true
@export var world_bounds: Rect2 = Rect2(-96, -64, 512, 384)
@export var outfield_wall_y: float = 16.0
@export var left_foul_pole: Vector2 = Vector2(48, 16)
@export var right_foul_pole: Vector2 = Vector2(272, 16)

@export_group("Juice")
@export var hr_hitstop_sec: float = 1.6       # 1.5–2.0 sec

var _plate: Node2D
var _ball: Node2D = null
var _tracking := false
var _hr_fx_running := false

func _ready() -> void:
	_plate = get_node_or_null(home_plate_path)
	add_to_group("field_judge")
	reconfigure_layout()
	call_deferred("reconfigure_layout")
	set_physics_process(true)
	if draw_debug:
		queue_redraw()

func reconfigure_layout() -> void:
	if _plate == null:
		push_warning("[FieldJudge] home_plate_path is not set; cannot reconfigure.")
		return

	var home := _plate.global_position
	var w := desired_field_size.x
	var h := desired_field_size.y

	var left := home.x - w * 0.5
	var top  := home.y - (h - bottom_margin_px)
	world_bounds = Rect2(left, top, w, h)

	outfield_wall_y = world_bounds.position.y + top_margin_px
	left_foul_pole  = Vector2(world_bounds.position.x + side_margin_px, outfield_wall_y)
	right_foul_pole = Vector2(world_bounds.position.x + world_bounds.size.x - side_margin_px, outfield_wall_y)

	var dir_left  := (left_foul_pole  - home)
	var dir_right := (right_foul_pole - home)
	if dir_left.length() > 0.0001:
		dir_left = dir_left.normalized()
	else:
		dir_left = Vector2(-0.7, -0.7).normalized()
	if dir_right.length() > 0.0001:
		dir_right = dir_right.normalized()
	else:
		dir_right = Vector2(0.7, -0.7).normalized()

	var bisector := dir_left + dir_right
	if bisector.length() > 0.0001:
		bisector = bisector.normalized()
	else:
		bisector = Vector2(0, -1)

	var first_pos  := home + dir_right * base_side_px
	var third_pos  := home + dir_left  * base_side_px
	var second_pos := home + bisector  * base_side_px * sqrt(2.0)

	var first  := get_node_or_null(first_base_path)  as Node2D
	var second := get_node_or_null(second_base_path) as Node2D
	var third  := get_node_or_null(third_base_path)  as Node2D
	if first:
		first.global_position  = first_pos
	if second:
		second.global_position = second_pos
	if third:
		third.global_position  = third_pos

	if draw_debug:
		queue_redraw()

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

	# Foul-line X at this Y
	var xl := _line_x_at_y(p, left_foul_pole, pos.y)
	var xr := _line_x_at_y(p, right_foul_pole, pos.y)
	if xl > xr:
		var t := xl; xl = xr; xr = t
	xl -= foul_margin_px
	xr += foul_margin_px

	# HR first
	if pos.y <= outfield_wall_y and pos.x >= xl and pos.x <= xr:
		if not (_ball.has_meta("hr_announced") and _ball.get_meta("hr_announced")):
			_ball.set_meta("hr_announced", true)
			GameManager.call_hit(true)     # HUD HR strobe
			_home_run_juice()              # long pause-based freeze + strobe, with watchdog
		_end_play()
		return

	# Foul
	if pos.x < xl or pos.x > xr:
		if not (_ball.has_meta("ruled") and _ball.get_meta("ruled")):
			_ball.set_meta("ruled", true)
			GameManager.call_foul()
		_end_play()
		return

	# Safety: if ball leaves world
	if not world_bounds.has_point(pos):
		_end_play()
		return

func _end_play() -> void:
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("follow_default"):
		cam.follow_default()
	GameManager.end_play()
	_tracking = false
	_ball = null

func _line_x_at_y(a: Vector2, b: Vector2, y: float) -> float:
	var dy := (a.y - b.y)
	if absf(dy) < 0.0001:
		return a.x
	var t := (a.y - y) / dy
	return a.x + (b.x - a.x) * t

# ---------------- HR Juice (pause-only, safe watchdog) ----------------
func _home_run_juice() -> void:
	if _hr_fx_running:
		return
	_hr_fx_running = true
	call_deferred("_hr_fx_coroutine")

func _hr_fx_coroutine() -> void:
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(2.0, 0.10)

	# HUD/Screen juice if available
	var juice := get_node_or_null("/root/Juice")
	if juice:
		if juice.has_method("flash"):
			juice.call("flash", Color(1,1,1,0.90), 0.20)
		if juice.has_method("strobe"):
			juice.call("strobe", [Color(1,1,1,0.90), Color(1,0.2,0.2,0.90)], hr_hitstop_sec * 0.6, 0.10)

	# Use SceneTree pause (not time_scale) + ignore_time_scale timer
	var tree := get_tree()
	var prev_paused := tree.paused
	tree.paused = true

	var t := tree.create_timer(hr_hitstop_sec, true, true) # process_always + ignore_time_scale
	await t.timeout

	tree.paused = prev_paused

	# Watchdog: guarantee resume even if something else interferes
	var guard := tree.create_timer(hr_hitstop_sec + 0.3, true, true)
	await guard.timeout
	if tree.paused:
		tree.paused = false
	if Engine.time_scale < 0.95:
		Engine.time_scale = 1.0

	_hr_fx_running = false

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
	draw_line(to_local(wl), to_local(wr), Color(0.3,1,0.5,0.7), 1.0, false)

	# Bounds + diamond
	draw_rect(Rect2(to_local(world_bounds.position), world_bounds.size), Color(1,1,1,0.10), false)

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
		draw_circle(F, 3.0, Color(0.8,1,0.8,0.9))
		draw_circle(S, 3.0, Color(0.8,0.8,1,0.9))
		draw_circle(T, 3.0, Color(1,0.8,0.8,0.9))
