extends Node
class_name CpuBatter

@export var batter_path: NodePath
@export var home_plate_path: NodePath

@export_group("Timing")
@export var min_reaction: float = 0.06
@export var max_reaction: float = 0.14
@export var min_t_to_swing: float = 0.045

@export_group("Strike Window (px)")
@export var zone_half_width: float = 14.0
@export var zone_soft_edge: float = 8.0

@export_group("LR Bias")
@export var lr_bias_strength: float = 0.55

var _b: Batter
var _plate: Node2D
var _hud: Node
var _enabled := false

func _ready() -> void:
	_b = get_node_or_null(batter_path) as Batter
	_plate = get_node_or_null(home_plate_path) as Node2D
	_hud = get_tree().get_first_node_in_group("umpire_hud")
	set_physics_process(true)

func activate() -> void:
	_enabled = true
	_show_ai_tag(true)

func deactivate() -> void:
	_enabled = false
	_show_ai_tag(false)

func _physics_process(_delta: float) -> void:
	if not _enabled or _b == null or _plate == null:
		return

	var best_ball = null
	var best_t := 1e9
	var best_v := Vector2.ZERO

	for node in get_tree().get_nodes_in_group("balls"):
		if node == null or not (node is Node2D):
			continue
		var ball := node as Node2D
		var v := _get_ball_velocity(ball)
		if v.y <= 0.0:
			continue

		var contact_y = (_b._contact_point()).y
		var dy = contact_y - ball.global_position.y
		if dy <= 0.0:
			continue

		var t = dy / v.y
		if t < best_t:
			best_t = t
			best_ball = ball
			best_v = v

	if best_ball == null or best_t <= 0.0:
		return

	var bx := (best_ball as Node2D).global_position.x
	var plate_x := _plate.global_position.x
	var predicted_x := bx + best_v.x * best_t
	var dx = abs(predicted_x - plate_x)

	var soft := zone_half_width + zone_soft_edge
	var strike_prob := 0.0
	if dx <= zone_half_width:
		strike_prob = 1.0
	else:
		var denom = max(1.0, soft - zone_half_width)
		strike_prob = clamp(1.0 - ((dx - zone_half_width) / denom), 0.0, 1.0)

	var react := randf_range(min_reaction, max_reaction)
	if strike_prob > 0.45:
		_b.ai_set_lr_bias((1.0 if predicted_x - plate_x > 0.0 else -1.0) * lr_bias_strength)
		var swing_in = max(0.0, best_t - react)
		_b.ai_swing_after(swing_in)

func _get_ball_velocity(ball: Node2D) -> Vector2:
	if ball.has_method("get_velocity"):
		return ball.get_velocity()
	var v := Vector2.ZERO
	if ball.has_method("get"):
		var maybe = ball.get("velocity")
		if typeof(maybe) == TYPE_VECTOR2:
			v = maybe
	return v

# ----- AI tag (2×2 red pixel) -----
func _show_ai_tag(on: bool) -> void:
	if _b == null:
		return
	var host := _b as Node2D
	if host == null:
		return
	var tag := host.get_node_or_null("_AITag") as Sprite2D
	if on:
		if tag == null:
			tag = Sprite2D.new()
			tag.name = "_AITag"
			tag.centered = true
			tag.position = Vector2(0, -10)
			tag.z_index = 999
			var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
			img.fill(Color(1,0,0,1))
			var tex := ImageTexture.create_from_image(img)
			tag.texture = tex
			host.add_child(tag)
		tag.visible = true
	else:
		if tag != null:
			tag.visible = false
