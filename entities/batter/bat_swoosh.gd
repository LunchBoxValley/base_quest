extends Node2D
class_name BatSwoosh

@export_group("Look")
@export var base_color: Color = Color(1, 1, 1, 0.9)
@export var trail_color: Color = Color(1, 1, 1, 0.45)     # faint, wider pass for a soft edge
@export var thickness_px: float = 6.0
@export var extra_trail_width_px: float = 3.0            # adds to thickness for the faint pass

@export_group("Geometry")
@export var radius_px: float = 24.0
@export var start_angle_rad: float = deg_to_rad(-60.0)
@export var end_angle_rad: float   = deg_to_rad(30.0)
@export var center_offset: Vector2 = Vector2.ZERO        # local offset from this node's origin

@export_group("Timing")
@export var life_sec: float = 0.12                       # how long the swoosh stays visible
@export var fade_out: bool = true

@export_group("Quality")
@export var max_step_deg: float = 6.0                    # segment size (smaller = smoother)
@export var antialiased: bool = true

var _t_left: float = 0.0

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if _t_left > 0.0:
		_t_left -= delta
		if _t_left < 0.0:
			_t_left = 0.0
		queue_redraw()

func _draw() -> void:
	if _t_left <= 0.0:
		return

	var col_main := base_color
	var col_trail := trail_color
	if fade_out and life_sec > 0.0:
		var k = clamp(_t_left / life_sec, 0.0, 1.0)
		k = k * k # slight ease-out
		col_main.a = base_color.a * k
		col_trail.a = trail_color.a * k

	var pts := _compute_arc_points(center_offset, radius_px, start_angle_rad, end_angle_rad, max_step_deg)
	if pts.size() < 2:
		return

	# Soft “glow” pass (wider, faint)
	var wide = max(1.0, thickness_px + extra_trail_width_px)
	draw_polyline(pts, col_trail, wide, antialiased)

	# Main pass (narrower, brighter)
	draw_polyline(pts, col_main, max(1.0, thickness_px), antialiased)

# ---------------- Public API ----------------

# Fire a swoosh with optional overrides.
func fire(
	new_center_offset: Variant = null,
	new_radius_px: float = -1.0,
	new_start_angle_rad: float = INF,
	new_end_angle_rad: float = INF,
	new_thickness_px: float = -1.0,
	new_color: Variant = null,
	new_trail_color: Variant = null,
	new_life_sec: float = -1.0
) -> void:
	if new_center_offset != null:
		center_offset = new_center_offset
	if new_radius_px > 0.0:
		radius_px = new_radius_px
	if new_start_angle_rad != INF:
		start_angle_rad = new_start_angle_rad
	if new_end_angle_rad != INF:
		end_angle_rad = new_end_angle_rad
	if new_thickness_px > 0.0:
		thickness_px = new_thickness_px
	if new_color != null and new_color is Color:
		base_color = new_color
	if new_trail_color != null and new_trail_color is Color:
		trail_color = new_trail_color
	if new_life_sec > 0.0:
		life_sec = new_life_sec

	_t_left = life_sec
	queue_redraw()

# Convenience: set arc from degrees (friendlier for tuning in code)
func fire_deg(a0_deg: float, a1_deg: float, power_0_to_1: float = 1.0) -> void:
	start_angle_rad = deg_to_rad(a0_deg)
	end_angle_rad   = deg_to_rad(a1_deg)
	thickness_px    = lerp(4.0, 8.0, clamp(power_0_to_1, 0.0, 1.0))
	_t_left = life_sec
	queue_redraw()

# ---------------- Internals ----------------

func _compute_arc_points(center_local: Vector2, r: float, a0: float, a1: float, step_deg: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if r <= 0.1:
		return pts
	var span := a1 - a0
	if is_equal_approx(span, 0.0):
		return pts

	# Clamp span to a sane range
	span = clamp(span, -TAU, TAU)

	var step_rad := deg_to_rad(clamp(step_deg, 1.0, 30.0))
	var steps := maxi(2, int(ceil(abs(span) / step_rad)))

	pts.resize(steps + 1)
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var ang := a0 + span * t
		pts[i] = center_local + Vector2(cos(ang), sin(ang)) * r
	return pts
