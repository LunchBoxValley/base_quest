extends Camera2D
class_name GameCamera

@export var default_target_path: NodePath      # usually ../Entities/Pitcher
@export var field_path: NodePath               # Field node (FieldJudge) for limits
@export var follow_lerp_speed: float = 10.0

# Pre-pitch framing: pitcher 1/3 from top, centered X
@export var default_x_ratio: float = 0.5
@export var default_y_ratio: float = 1.0 / 3.0

# -------- Charge zoom (relative to baseline) --------
@export var charge_zoom_amount: float = 0.20        # 0.20 = 20% closer
@export var charge_zoom_in_time: float = 0.35       # slow ease-in while charging
@export var charge_zoom_out_time: float = 0.05      # quick snap back
@export var charge_zoom_snap_on_release: bool = true

var _baseline_zoom: Vector2 = Vector2.ONE
var _zoom_tw: Tween = null

var _target: Node2D
var _use_offset: bool = true   # true = offset framing (pitcher), false = center (ball)

# Tiny camera kick (microshake)
var _kick_offset := Vector2.ZERO
var _kick_time := 0.0
var _kick_len := 0.0

func _ready() -> void:
	enabled = true
	add_to_group("game_camera")
	_apply_field_limits()
	_baseline_zoom = zoom                       # capture whatever you set in the editor
	follow_default(true)

func _apply_field_limits() -> void:
	var field := get_node_or_null(field_path)
	if field and field.has_method("get_world_bounds"):
		var r: Rect2 = field.get_world_bounds()
		limit_left = int(r.position.x)
		limit_top = int(r.position.y)
		limit_right = int(r.position.x + r.size.x)
		limit_bottom = int(r.position.y + r.size.y)
		limit_smoothed = true

func follow_default(snap: bool = false) -> void:
	_use_offset = true
	if default_target_path != NodePath():
		var d := get_node_or_null(default_target_path)
		if d is Node2D:
			_target = d
			if snap:
				global_position = _desired_cam_pos_for(_target.global_position, true)

func follow_target(node: Node2D, snap: bool = false) -> void:
	if node == null:
		return
	_use_offset = false  # center on ball while pitching/hit
	_target = node
	if snap:
		global_position = _desired_cam_pos_for(_target.global_position, false)

func kick(strength_px := 2.0, duration := 0.12) -> void:
	_kick_offset = Vector2(randf() * 2.0 - 1.0, 1.0).normalized() * strength_px
	_kick_time = duration
	_kick_len = duration

# -------- Charge zoom API (called by Pitcher) --------
func charge_zoom_start() -> void:
	_kill_zoom_tween()
	var amt = clamp(charge_zoom_amount, 0.0, 0.9)
	var target = _baseline_zoom * (1.0 + amt)      # >1 zooms IN
	_zoom_tw = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_zoom_tw.tween_property(self, "zoom", target, charge_zoom_in_time)

func charge_zoom_end() -> void:
	_kill_zoom_tween()
	if charge_zoom_snap_on_release or charge_zoom_out_time <= 0.0:
		zoom = _baseline_zoom                         # instant snap
	else:
		_zoom_tw = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_zoom_tw.tween_property(self, "zoom", _baseline_zoom, charge_zoom_out_time)

func _kill_zoom_tween() -> void:
	if _zoom_tw and _zoom_tw.is_valid():
		_zoom_tw.kill()
		_zoom_tw = null

func _process(delta: float) -> void:
	if _target == null:
		return
	var desired := _desired_cam_pos_for(_target.global_position, _use_offset)
	if _kick_time > 0.0:
		_kick_time -= delta
		var k = clamp(_kick_time / max(_kick_len, 0.00001), 0.0, 1.0)
		desired += _kick_offset * k

	var t = clamp(delta * follow_lerp_speed, 0.0, 1.0)
	var nx = lerp(global_position.x, desired.x, t)
	var ny = lerp(global_position.y, desired.y, t)
	global_position = Vector2(round(nx), round(ny))  # pixel-perfect

func _desired_cam_pos_for(tpos: Vector2, use_offset: bool) -> Vector2:
	if not use_offset:
		return tpos
	var vsize := get_viewport_rect().size
	var vcenter := vsize * 0.5
	var desired_screen := Vector2(vsize.x * default_x_ratio, vsize.y * default_y_ratio)
	return tpos + (vcenter - desired_screen)
