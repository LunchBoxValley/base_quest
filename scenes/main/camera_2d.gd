# res://systems/GameCamera.gd
extends Camera2D
class_name GameCamera

@export var enable_on_start: bool = true

@export_group("Targets & Offsets")
@export var default_target_path: NodePath                 # e.g., Pitcher node or a MoundFocus marker
@export var default_offset: Vector2 = Vector2(0, -60)     # pre-pitch framing (pitcher ~1/3 from top)
@export var follow_ball_offset: Vector2 = Vector2.ZERO    # usually centered on ball
@export var charge_focus_offset: Vector2 = Vector2.ZERO   # EXACT center on pitcher while charging

@export_group("Follow Speeds")
@export var follow_lerp_speed: float = 8.0                # normal follow smoothing
@export var charge_focus_lerp_speed: float = 1000.0       # effectively snap while charging
@export var ball_follow_lerp_speed: float = 10.0          # a tad snappier for batted balls

@export_group("World Bounds")
@export var bounds_enabled: bool = true
@export var bounds_rect: Rect2 = Rect2(Vector2.ZERO, Vector2(640, 360))  # your 640×360 field
@export var clamp_during_charge: bool = false             # usually FALSE to avoid offset while zooming in

@export_group("Follow Overscroll")
@export var follow_overscroll_enabled: bool = true        # allow camera to go a bit beyond bounds when following ball
@export var follow_overscroll_pad: Vector2 = Vector2(48, 32)  # extra px beyond bounds while following

@export_group("Post-Play Return")
@export var post_play_hold_time: float = 0.40             # pause after play ends
@export var return_to_pitch_time: float = 0.70            # ease duration back to pitcher

# --- Internal state ---
var _default_target: Node2D = null
var _target: Node2D = null
var _ball_following: Node2D = null
var _charge_focus_active: bool = false
var _charge_target: Node2D = null

var _hold_after_play: float = 0.0
var _returning: bool = false
var _return_tw: Tween = null

# Tiny screen shake (optional)
var _shake_t: float = 0.0
var _shake_dur: float = 0.0
var _shake_amp: float = 0.0

func _ready() -> void:
	enabled = enable_on_start
	add_to_group("game_camera")
	_default_target = get_node_or_null(default_target_path) as Node2D
	_target = _default_target
	global_position = _desired_position(true)  # snap at start

func _process(delta: float) -> void:
	# Hold freeze after play ends
	if _hold_after_play > 0.0:
		_hold_after_play = max(0.0, _hold_after_play - delta)
		_apply_shake(delta)
		if _hold_after_play == 0.0:
			_start_return_to_default()
		return

	# While tweening back, let the tween drive position
	if _returning:
		_apply_shake(delta)
		return

	var target_pos := _desired_position(false)
	var speed := follow_lerp_speed
	if _charge_focus_active:
		speed = charge_focus_lerp_speed
	elif is_instance_valid(_ball_following):
		speed = ball_follow_lerp_speed

	var alpha = clamp(delta * speed, 0.0, 1.0)
	global_position = global_position.lerp(target_pos, alpha)

	_apply_shake(delta)

func _apply_shake(delta: float) -> void:
	if _shake_t <= 0.0:
		return
	_shake_t = max(0.0, _shake_t - delta)
	var k = _shake_t / max(0.0001, _shake_dur)
	var amp = _shake_amp * (k * k)
	var jitter = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amp
	global_position += jitter

func _desired_position(snap: bool) -> Vector2:
	var pos := global_position

	if _charge_focus_active and is_instance_valid(_charge_target):
		pos = _charge_target.global_position + charge_focus_offset
		if clamp_during_charge:
			pos = _clamp_to_bounds(pos, Vector2.ZERO)
		return pos

	if is_instance_valid(_ball_following):
		pos = _ball_following.global_position + follow_ball_offset
		var pad := Vector2.ZERO
		if follow_overscroll_enabled:
			pad = follow_overscroll_pad
		return _clamp_to_bounds(pos, pad)

	if is_instance_valid(_target):
		pos = _target.global_position + default_offset
		return _clamp_to_bounds(pos, Vector2.ZERO)

	return _clamp_to_bounds(pos, Vector2.ZERO)

# Clamp to bounds, optionally expanding by 'pad' so the camera can go beyond the field a bit
func _clamp_to_bounds(p: Vector2, pad: Vector2) -> Vector2:
	if not bounds_enabled:
		return p
	var view := get_viewport_rect().size
	var half := Vector2(view.x * 0.5 * zoom.x, view.y * 0.5 * zoom.y)
	var minp := bounds_rect.position + half - pad
	var maxp := bounds_rect.position + bounds_rect.size - half + pad
	p.x = clamp(p.x, minp.x, maxp.x)
	p.y = clamp(p.y, minp.y, maxp.y)
	return p

# -------- Public API --------

# Center on the pitcher (or any node) during charge; ignores default_offset.
func begin_charge_focus(target: Node2D, snap: bool = true) -> void:
	if not is_instance_valid(target):
		return
	_cancel_return_sequence()
	_charge_focus_active = true
	_charge_target = target
	_ball_following = null
	_target = target
	if snap:
		global_position = _desired_position(true)

# Stop charge focus; go back to pitcher framing (default_offset applied again).
func end_charge_focus(snap: bool = false) -> void:
	_charge_focus_active = false
	_charge_target = null
	focus_default(snap)

# Follow a ball until it ends.
func follow_target(node: Node2D, snap: bool = true) -> void:
	if not is_instance_valid(node):
		return
	_cancel_return_sequence()

	# Disconnect prior ball hooks
	if is_instance_valid(_ball_following):
		if _ball_following.has_signal("out_of_play"):
			if _ball_following.is_connected("out_of_play", Callable(self, "_on_followed_ball_over")):
				_ball_following.disconnect("out_of_play", Callable(self, "_on_followed_ball_over"))
		if _ball_following.is_connected("tree_exited", Callable(self, "_on_followed_ball_tree_exited")):
			_ball_following.disconnect("tree_exited", Callable(self, "_on_followed_ball_tree_exited"))

	_ball_following = node
	_target = node

	if node.has_signal("out_of_play"):
		node.out_of_play.connect(_on_followed_ball_over, CONNECT_ONE_SHOT)
	node.tree_exited.connect(_on_followed_ball_tree_exited, CONNECT_ONE_SHOT)

	if snap:
		global_position = _desired_position(true)

# Focus pitcher/default again immediately (no hold / no slow tween).
func focus_default(snap: bool = false) -> void:
	_ball_following = null
	_target = _default_target
	if snap:
		global_position = _desired_position(true)

# Tiny camera kick
func kick(amplitude: float = 2.0, duration: float = 0.12) -> void:
	_shake_amp = max(0.0, amplitude)
	_shake_dur = max(0.0001, duration)
	_shake_t = _shake_dur

# -------- Post-play sequencing --------
func _on_followed_ball_over() -> void:
	_ball_following = null
	_hold_after_play = post_play_hold_time   # pause at ball’s last position

func _on_followed_ball_tree_exited() -> void:
	_ball_following = null
	_hold_after_play = post_play_hold_time

func _start_return_to_default() -> void:
	_returning = true
	_target = _default_target
	var goal := _desired_position(true)  # pitcher + default_offset, clamped
	_kill_return_tween()
	_return_tw = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_return_tw.tween_property(self, "global_position", goal, return_to_pitch_time)
	_return_tw.tween_callback(Callable(self, "_on_return_finished"))

func _on_return_finished() -> void:
	_returning = false
	_return_tw = null

func _kill_return_tween() -> void:
	if _return_tw and _return_tw.is_valid():
		_return_tw.kill()
		_return_tw = null

func _cancel_return_sequence() -> void:
	_hold_after_play = 0.0
	_returning = false
	_kill_return_tween()
