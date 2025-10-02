extends Node2D
class_name FieldJudge

signal foul_ball
signal home_run

@export_group("Scene Paths")
@export var home_plate_path: NodePath
@export var first_base_path: NodePath
@export var second_base_path: NodePath
@export var third_base_path: NodePath
@export var pitcher_path: NodePath

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
@export var hr_hitstop_sec: float = 1.6

@export_group("Outfield Walls")
@export var back_wall_height_px: float = 12.0
@export var side_wall_height_px: float = 8.0
@export var side_wall_width_px: float = 4.0
@export var wall_bounce_damping: float = 0.85         # side posts (legacy)
@export var wall_random_angle_deg: float = 12.0       # side posts (legacy)
# NEW: back-wall specific damping/angle so rebounds keep only ~10–20% speed
@export var back_wall_bounce_damping: float = 0.15
@export var back_wall_random_angle_deg: float = 8.0

@export_group("HR Tuning")
@export var hr_clearance_bias_px: float = 2.0
@export var debug_force_hr_clear: bool = false
@export var debug_force_requires_air: bool = true

# ---------------- Zoning (infield/outfield + left/right) ----------------
@export_group("Zoning / Fielders")
@export var first_baseman_path: NodePath
@export var second_baseman_path: NodePath
@export var third_baseman_path: NodePath
@export var left_fielder_path: NodePath
@export var right_fielder_path: NodePath

@export var infield_radius_px: float = 150.0
@export var zone_stickiness_px: float = 24.0

var _plate: Node2D
var _ball: Node2D = null
var _tracking := false
var _hr_fx_running := false
var _zone_claimer: Node = null  # soft memory to reduce thrash; optional

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

	var dir_left := (left_foul_pole - home)
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
	if first:  first.global_position  = first_pos
	if second: second.global_position = second_pos
	if third:  third.global_position  = third_pos

	if draw_debug:
		queue_redraw()

func track_batted_ball(ball: Node2D) -> void:
	_ball = ball
	_tracking = is_instance_valid(_ball)
	if not _tracking:
		return

	# End-of-play cleanup
	if _ball.has_signal("out_of_play"):
		_ball.out_of_play.connect(func():
			_tracking = false
			_ball = null
		)

	# Wall-hit juice hook
	if _ball.has_signal("wall_hit"):
		if not _ball.is_connected("wall_hit", Callable(self, "_on_ball_wall_hit")):
			_ball.connect("wall_hit", Callable(self, "_on_ball_wall_hit"))

func _physics_process(_delta: float) -> void:
	if not _tracking or not is_instance_valid(_ball) or _plate == null:
		return

	var p := _plate.global_position
	var pos := _ball.global_position

	# Foul-line X at this Y
	var xl := _line_x_at_y(p, left_foul_pole, pos.y)
	var xr := _line_x_at_y(p, right_foul_pole, pos.y)
	if xl > xr:
		var tmp := xl; xl = xr; xr = tmp
	xl -= foul_margin_px
	xr += foul_margin_px

	# 1) Pure 2D HR (already above the top line)
	if pos.y <= outfield_wall_y and pos.x >= xl and pos.x <= xr:
		_award_hr_then_end()
		return

	# --------- BACK WALL BAND (height-aware) ---------
	if pos.y > outfield_wall_y and pos.y <= outfield_wall_y + back_wall_height_px and pos.x >= xl and pos.x <= xr:
		# Optional debug: only if airborne (prevents rollers from becoming HR)
		if debug_force_hr_clear:
			var airborne_height := _safe_height_px()
			if (not debug_force_requires_air) or airborne_height > 0.1:
				_award_hr_then_end()
				return
		var height_px := _safe_height_px() + hr_clearance_bias_px
		if height_px >= back_wall_height_px:
			_award_hr_then_end()
			return
		# Use strong damping on the BACK WALL only (~10–20% speed kept)
		_bounce_ball_with(Vector2(0, 1), back_wall_bounce_damping, back_wall_random_angle_deg)
		return

	# --------- SIDE POSTS (outside foul lines) ---------
	var y_low := outfield_wall_y
	var y_high := outfield_wall_y + side_wall_height_px
	if pos.y >= y_low and pos.y <= y_high:
		if pos.x >= xl - side_wall_width_px and pos.x < xl:
			_bounce_ball(Vector2(1, 0))   # side posts use legacy damping/angle
			return
		if pos.x > xr and pos.x <= xr + side_wall_width_px:
			_bounce_ball(Vector2(-1, 0))  # side posts use legacy damping/angle
			return

	# ---------------- FOUL ----------------
	if pos.x < xl or pos.x > xr:
		if not (_ball.has_meta("ruled") and _ball.get_meta("ruled")):
			_ball.set_meta("ruled", true)
			# Tag for timed cleanup + broadcast (Ball.mark_foul handles fade/despawn)
			if _ball.has_method("mark_foul"):
				_ball.call("mark_foul")
			foul_ball.emit()
			GameManager.call_foul()
		_end_play()
		return

	# Safety: out of world
	if not world_bounds.has_point(pos):
		_end_play()
		return

func _safe_height_px() -> float:
	if is_instance_valid(_ball) and _ball.has_method("get_height_px"):
		return float(_ball.call("get_height_px"))
	return 0.0

func _award_hr_then_end() -> void:
	if not (_ball.has_meta("hr_announced") and _ball.get_meta("hr_announced")):
		_ball.set_meta("hr_announced", true)
		GameManager.call_hit(true)
		_home_run_juice()
	_end_play()

func _on_ball_wall_hit(_normal: Vector2) -> void:
	# Camera micro-kick (lighter than HR)
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(0.8, 0.06)
	# Minimal screen flash (guarded)
	var juice := get_node_or_null("/root/Juice")
	if juice:
		if juice.has_method("flash"):
			juice.call("flash", Color(1,1,1,0.25), 0.05)
		elif juice.has_method("strobe"):
			juice.call("strobe", [Color(1,1,1,0.20), Color(1,1,1,0.10)], 0.08, 0.04)

func _bounce_ball(normal: Vector2) -> void:
	if is_instance_valid(_ball) and _ball.has_method("wall_bounce"):
		_ball.call("wall_bounce", normal, wall_bounce_damping, wall_random_angle_deg)
	else:
		_end_play()

# NEW: custom damping/angle bounce (used by back wall)
func _bounce_ball_with(normal: Vector2, damping: float, random_angle_deg: float) -> void:
	if is_instance_valid(_ball) and _ball.has_method("wall_bounce"):
		_ball.call("wall_bounce", normal, clamp(damping, 0.0, 1.0), random_angle_deg)
	else:
		_end_play()

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

	var juice := get_node_or_null("/root/Juice")
	if juice:
		if juice.has_method("flash"):
			juice.call("flash", Color(1,1,1,0.90), 0.20)
		if juice.has_method("strobe"):
			juice.call("strobe", [Color(1,1,1,0.90), Color(1,0.2,0.2,0.90)], hr_hitstop_sec * 0.6, 0.10)

	var tree := get_tree()
	var prev_paused := tree.paused
	tree.paused = true
	var t := tree.create_timer(hr_hitstop_sec, true, true)
	await t.timeout
	tree.paused = prev_paused

	var guard := tree.create_timer(hr_hitstop_sec + 0.3, true, true)
	await guard.timeout
	if tree.paused:
		tree.paused = false
	if Engine.time_scale < 0.95:
		Engine.time_scale = 1.0
	_hr_fx_running = false

# ---------------- Fielder Throw Target API (minimal, non-breaking) ----------------
func choose_force_base(team_id: int) -> Node:
	var base1 := get_node_or_null(first_base_path)
	if base1:
		return base1
	var pitcher := get_node_or_null(pitcher_path)
	if pitcher:
		return pitcher
	return null

# ---------------- Zone Ownership API (additive) ----------------
func choose_zone_fielder_for_point(point: Vector2) -> Node:
	var home := _plate if _plate else get_node_or_null(home_plate_path)
	if home == null:
		return null
	var home_pos := (home as Node2D).global_position
	var d := home_pos.distance_to(point)

	# Infield: nearest of 1B/2B/3B to the point
	if d <= infield_radius_px:
		var best_node: Node = null
		var best_dist := INF
		for path in [first_base_path, second_base_path, third_base_path]:
			var base := get_node_or_null(path) as Node2D
			if base:
				var dist := base.global_position.distance_to(point)
				if dist < best_dist:
					best_dist = dist
					best_node = _fielder_from_base_path(path)
		return best_node
	# Outfield: left/right by side of home->second midline
	else:
		var second := get_node_or_null(second_base_path) as Node2D
		var mid_dir := Vector2(0, -1)
		if second:
			mid_dir = (second.global_position - home_pos).normalized()
		var to_point := (point - home_pos).normalized()
		var cross := mid_dir.x * to_point.y - mid_dir.y * to_point.x
		if cross > 0.0:
			return get_node_or_null(left_fielder_path)
		else:
			return get_node_or_null(right_fielder_path)

# Sticky assignment to reduce ping-pong at zone edges.
func update_zone_claimer_for_point(point: Vector2) -> Node:
	var candidate := choose_zone_fielder_for_point(point)
	if _zone_claimer and candidate:
		var cur_pos := _get_node_global_or_null(_zone_claimer)
		var cand_pos := _get_node_global_or_null(candidate)
		if cur_pos.x != INF and cand_pos.x != INF:
			var cur_d := (cur_pos - point).length()
			var new_d := (cand_pos - point).length()
			if cur_d <= new_d + zone_stickiness_px:
				return _zone_claimer
	_zone_claimer = candidate
	return _zone_claimer

# Convenience: preferred chaser for a live ball.
func choose_fielder_for_ball(ball: Node2D) -> Node:
	if ball == null:
		return null
	return update_zone_claimer_for_point(ball.global_position)

# Resolve from a base NodePath to its corresponding fielder NodePath.
func _fielder_from_base_path(path: NodePath) -> Node:
	if path == first_base_path:
		return get_node_or_null(first_baseman_path)
	if path == second_base_path:
		return get_node_or_null(second_baseman_path)
	if path == third_base_path:
		return get_node_or_null(third_baseman_path)
	return null

func _get_node_global_or_null(n: Node) -> Vector2:
	if n and n is Node2D:
		return (n as Node2D).global_position
	return Vector2(INF, INF)

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

	# Back wall band (debug)
	var back_rect := Rect2(Vector2(wl.x, outfield_wall_y), Vector2(wr.x - wl.x, back_wall_height_px))
	draw_rect(Rect2(to_local(back_rect.position), back_rect.size), Color(0.1,0.9,0.4,0.10), true)

	# Side posts (debug) — outside foul lines
	var p := _plate.global_position
	var xl := _line_x_at_y(p, left_foul_pole, outfield_wall_y)
	var xr := _line_x_at_y(p, right_foul_pole, outfield_wall_y)
	var left_rect  := Rect2(Vector2(xl - side_wall_width_px, outfield_wall_y), Vector2(side_wall_width_px, side_wall_height_px))
	var right_rect := Rect2(Vector2(xr, outfield_wall_y),                      Vector2(side_wall_width_px, side_wall_height_px))
	draw_rect(Rect2(to_local(left_rect.position),  left_rect.size),  Color(0.2,0.6,1.0,0.14), true)
	draw_rect(Rect2(to_local(right_rect.position), right_rect.size), Color(0.2,0.6,1.0,0.14), true)

	# Diamond
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
