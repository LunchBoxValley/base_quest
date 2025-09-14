# res://entities/HomePlate.gd
extends Node2D
class_name HomePlate

@export_group("Strike Zone")
@export var zone_size: Vector2 = Vector2(18, 24)     # width x height in px
@export var zone_offset: Vector2 = Vector2(0, -12)   # offset from this node (centered)
@export var debug_draw_zone: bool = false

@export_group("Detection")
@export var judge_once_per_ball: bool = true

# Optional sprite for plate art (not required)
@onready var plate_sprite: Sprite2D = null

# Track last positions and whether we've judged a ball already
var _last_pos := {}          # Dictionary<int, Vector2>
var _judged := {}            # Dictionary<int, bool>

func _ready() -> void:
	if has_node("Sprite"):
		plate_sprite = $Sprite

func _physics_process(_delta: float) -> void:
	var rect := _zone_global_rect()

	# Scan all active balls
	for node in get_tree().get_nodes_in_group("balls"):
		if node == null:
			continue
		if not (node is Node2D):
			continue
		var ball := node as Node2D
		var id := ball.get_instance_id()

		# Skip if we already judged this ball (and we only judge once)
		if judge_once_per_ball and _judged.has(id) and _judged[id]:
			continue

		# If the ball was hit by the batter, ignore it for strike/ball
		if ball.has_meta("batted") and ball.get_meta("batted") == true:
			_last_pos.erase(id)
			_judged.erase(id)
			continue

		var pos: Vector2 = ball.global_position
		var prev: Vector2 = pos
		if _last_pos.has(id):
			prev = _last_pos[id]
		else:
			_last_pos[id] = pos  # seed

		var inside_now := rect.has_point(pos)
		var inside_prev := rect.has_point(prev)

		# If the segment dipped into the zone at any point this frame -> STRIKE
		if inside_now or inside_prev:
			_mark_judged(id)
			_call_hud_strike()
			_last_pos[id] = pos
			continue

		# If we passed below the bottom of the zone this frame without entering -> BALL
		var bottom_y := rect.position.y + rect.size.y
		if prev.y <= bottom_y and pos.y > bottom_y:
			_mark_judged(id)
			_call_hud_ball()
			_last_pos[id] = pos
			continue

		_last_pos[id] = pos

	if debug_draw_zone:
		queue_redraw()  # Godot 4: use queue_redraw() instead of update()

func _mark_judged(id: int) -> void:
	if judge_once_per_ball:
		_judged[id] = true

func _zone_global_rect() -> Rect2:
	# Centered rect at node + offset
	var center := global_position + zone_offset
	var tl := center - zone_size * 0.5
	return Rect2(tl, zone_size)

func _draw() -> void:
	if not debug_draw_zone:
		return
	var r := _zone_global_rect()
	# Filled translucent zone
	draw_rect(r, Color(0.2, 1.0, 0.2, 0.12), true)
	# Outline (width = 1.0)
	draw_rect(r, Color(0.2, 1.0, 0.2, 0.7), false, 1.0)

# ---------------- HUD helpers ----------------
func _hud() -> Node:
	return get_tree().get_first_node_in_group("umpire_hud")

func _call_hud_strike() -> void:
	var h := _hud()
	if h and h.has_method("call_strike"):
		h.call("call_strike")

func _call_hud_ball() -> void:
	var h := _hud()
	if h and h.has_method("call_ball"):
		h.call("call_ball")
