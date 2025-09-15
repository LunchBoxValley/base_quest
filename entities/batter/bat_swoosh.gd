# BatSwoosh.gd — Godot 4.4.1 (no ternary)
# Draws a quick multi-stroke arc that fades out (right-handed by default).

extends Node2D

@export var radius: float = 28.0        # arc radius (px)
@export var arc_degrees: float = 120.0  # sweep size; bigger = longer arc
@export var thickness: float = 6.0      # base line thickness
@export var lines: int = 6              # how many parallel strokes
@export var spread: float = 8.0         # pixel spread across the stroke bundle
@export var color: Color = Color(1, 1, 1, 0.85)
@export var duration: float = 0.12      # total life (seconds)
@export var tail_shrink: float = 0.55   # how much the arc tail shortens over life (0..1)
@export var jitter: float = 1.2         # tiny wobble so lines aren’t identical
@export var right_handed: bool = true   # true = sweep across batter’s front from right shoulder

var _t: float = 1.0       # life progress 0..1 (1 = inactive)
var _seed: int = 0

func _ready() -> void:
	visible = false
	set_process(true)

func fire() -> void:
	_seed = randi()
	_t = 0.0
	visible = true
	modulate.a = 1.0
	queue_redraw()

func _process(delta: float) -> void:
	if _t >= 1.0:
		return
	_t = min(1.0, _t + delta / max(0.0001, duration))
	modulate.a = 1.0 - _t
	queue_redraw()
	if _t >= 1.0:
		visible = false

func _draw() -> void:
	if _t >= 1.0:
		return

	# Compute current sweep (Godot angles: 0° = +X, CW increases angle)
	var sweep := deg_to_rad(arc_degrees * (1.0 - tail_shrink * _t))
	var start_deg := -20.0
	var end_rad := deg_to_rad(start_deg)
	if right_handed:
		end_rad += sweep
	else:
		end_rad -= sweep

	var base_alpha := color.a * (1.0 - _t * 0.2)
	var base_col := Color(color.r, color.g, color.b, base_alpha)
	var base_thick = max(1.0, thickness * (1.0 - 0.6 * _t))

	# Draw multiple slightly offset ribbons to fake particle streaks
	for i in range(lines):
		var k := 0.0
		if lines > 1:
			k = float(i) / float(lines - 1) - 0.5
		var off := Vector2(0, k * spread)

		var noise := _rand_from_seed(1000 + _seed + i)
		var th = base_thick * (0.9 + 0.2 * noise)

		var line_alpha = base_col.a * (0.85 - 0.6 * abs(k))
		var col := Color(base_col.r, base_col.g, base_col.b, clampf(line_alpha, 0.0, 1.0))

		_draw_arc_stroke(off, radius, end_rad, th, col)

func _draw_arc_stroke(offset: Vector2, r: float, end_rad: float, base_thick: float, col: Color) -> void:
	var segs := 18
	var points: Array[Vector2] = []
	points.resize(segs + 1)

	for s in range(segs + 1):
		var t := float(s) / float(segs)
		var ang := end_rad * t
		var ease := 0.85 + 0.15 * t
		var rr := r * ease
		var p := Vector2(cos(ang), sin(ang)) * rr + offset
		# Tiny jitter to avoid perfectly clean lines
		p += Vector2(_rand_from_seed(17 + s) * 0.6, _rand_from_seed(43 + s) * 0.6)
		points[s] = p

	var ribbon := _polyline_to_ribbon(points, base_thick)
	draw_colored_polygon(ribbon, col)

func _polyline_to_ribbon(pts: Array[Vector2], width: float) -> PackedVector2Array:
	var half := width * 0.5
	var left: PackedVector2Array = PackedVector2Array()
	var right: PackedVector2Array = PackedVector2Array()
	left.resize(pts.size())
	right.resize(pts.size())

	for i in range(pts.size()):
		var p := pts[i]
		var dir := Vector2()
		if i == pts.size() - 1:
			dir = p - pts[i - 1]
		else:
			if i == 0:
				dir = pts[i + 1] - p
			else:
				dir = pts[i + 1] - pts[i - 1]
		if dir.length() == 0.0:
			dir = Vector2(1, 0)
		var normal := Vector2(-dir.y, dir.x).normalized()
		left[i] = p + normal * half
		right[i] = p - normal * half

	var poly: PackedVector2Array = PackedVector2Array()
	poly.resize(left.size() + right.size())
	for i in range(left.size()):
		poly[i] = left[i]
	for j in range(right.size()):
		poly[left.size() + j] = right[right.size() - 1 - j]
	return poly

func _rand_from_seed(n: int) -> float:
	# Deterministic 0..1 noise based on _seed and input n
	var x := int((_seed + n) & 0x7fffffff)
	x = (x * 1103515245 + 12345) & 0x7fffffff
	return float(x % 1000) / 1000.0
