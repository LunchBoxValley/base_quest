extends Node2D
class_name Pitcher

# ---------- Scenes & Nodes ----------
@export var ball_scene: PackedScene
@export var hand_path: NodePath            # Marker2D spawn (e.g. "Hand")
@export var camera_path: NodePath          # GameCamera (Camera2D with GameCamera.gd)
@export var pitch_charge_path: NodePath    # CPUParticles2D with PitchCharge.gd

# ---------- Pitch geometry ----------
@export var pitch_dir: Vector2 = Vector2.DOWN
@export var aim_angle_deg: float = 0.0     # left/center/right slots, etc.

# ---------- Charge & throw tuning ----------
@export var charge_full_time: float = 0.80
@export var phase_split: float = 0.60
@export var speed_min: float = 180.0
@export var speed_max: float = 340.0
@export var spread_deg_lo: float = 8.0
@export var spread_deg_hi: float = 0.8

# ---------- Camera juice ----------
@export var charge_zoom_in_mul: float = 1.20   # ≥1.0 zooms IN (20% closer)
@export var zoom_snap_time: float = 0.10

# ---------- Trail on fast pitch ----------
@export var fast_pitch_trail_threshold: float = 0.85  # fraction of full charge to show trail

# ---------- Internal state ----------
var _hand: Node2D
var _cam: Camera2D          # actually GameCamera, but safe-typed as Camera2D
var _fx: PitchCharge

var _charging: bool = false
var _charge_t: float = 0.0
var _play_locked: bool = false
var _current_ball: Ball = null
var _cam_zoom_base: Vector2 = Vector2.ONE

func _ready() -> void:
	_hand = get_node_or_null(hand_path)
	_cam = get_node_or_null(camera_path) as Camera2D
	_fx = get_node_or_null(pitch_charge_path) as PitchCharge

	if _cam:
		_cam.enabled = true

	if not InputMap.has_action("pitch"):
		InputMap.add_action("pitch")
		var ev := InputEventKey.new()
		ev.keycode = KEY_ENTER
		InputMap.action_add_event("pitch", ev)
		var ev2 := InputEventKey.new()
		ev2.keycode = KEY_KP_ENTER
		InputMap.action_add_event("pitch", ev2)

	if _fx:
		_fx.visible = false
		_fx.emitting = false

func _unhandled_input(event: InputEvent) -> void:
	if _play_locked:
		return
	if Input.is_action_just_pressed("pitch"):
		_start_charge()
	if Input.is_action_just_released("pitch"):
		if _charging:
			_release_pitch()

func _process(delta: float) -> void:
	if _charging:
		_advance_charge(delta)
		_apply_charge_zoom()
		_update_charge_fx()

# ---------------------- Charge lifecycle ----------------------
func _start_charge() -> void:
	if _play_locked:
		return
	_charging = true
	_charge_t = 0.0

	# Recenter camera on the pitcher (no offset) and start zoom-in
	if _cam:
		_cam_zoom_base = _cam.zoom
		if _cam.has_method("begin_charge_focus"):
			_cam.call("begin_charge_focus", self, true)

	if _fx:
		_fx.start_charge()

	_apply_charge_zoom()

func _advance_charge(delta: float) -> void:
	var dt = max(0.0001, charge_full_time)
	_charge_t = clamp(_charge_t + delta / dt, 0.0, 1.0)

func _release_pitch() -> void:
	_charging = false

	# split charge into power (phase 0) and accuracy (phase 1)
	var p_split = clamp(phase_split, 0.05, 0.95)
	var power_t = clamp(_charge_t / p_split, 0.0, 1.0)
	var acc_t := 0.0
	if _charge_t > p_split:
		acc_t = clamp((_charge_t - p_split) / (1.0 - p_split), 0.0, 1.0)

	var spd = lerp(speed_min, speed_max, _ease_out(power_t))

	var spread_deg = lerp(spread_deg_lo, spread_deg_hi, _ease_out(acc_t))
	var jitter_rad := deg_to_rad(spread_deg) * randf_range(-1.0, 1.0)

	var dir := pitch_dir.normalized().rotated(deg_to_rad(aim_angle_deg)).rotated(jitter_rad)

	if ball_scene == null:
		push_warning("Pitcher: ball_scene not assigned.")
		if _fx:
			_fx.release_burst(power_t)
		_end_charge_camera()
		return

	var start_pos: Vector2 = global_position
	if is_instance_valid(_hand):
		start_pos = _hand.global_position

	var b := ball_scene.instantiate()
	var host := get_parent()
	if host == null:
		host = get_tree().current_scene
	host.add_child(b)
	b.global_position = start_pos

	if b.has_method("pitch_from"):
		b.pitch_from(start_pos, dir, spd)
	else:
		if b.has_variable("_velocity"):
			b._velocity = dir.normalized() * spd

	if b is Ball:
		_current_ball = b

	# Fastball trail hint (only near full power)
	var show_trail = power_t >= clamp(fast_pitch_trail_threshold, 0.0, 1.0)
	var trail := b.get_node_or_null("Trail")
	if trail and (trail is Line2D):
		(trail as Line2D).visible = show_trail
		if not show_trail:
			(trail as Line2D).clear_points()

	# Lock mound until play ends
	_play_locked = true
	_hook_ball_end(b)

	# FX + camera reset (stop charge focus and snap zoom back)
	if _fx:
		_fx.release_burst(power_t)
	_end_charge_camera()

func _end_charge_camera() -> void:
	if _cam:
		if _cam.has_method("end_charge_focus"):
			_cam.call("end_charge_focus", false)
		_zoom_reset()

func _hook_ball_end(b: Node) -> void:
	if b.has_signal("out_of_play"):
		b.out_of_play.connect(_on_ball_out_of_play)
	b.tree_exited.connect(_on_ball_tree_exited)

func _on_ball_out_of_play() -> void:
	_unlock_after_play()

func _on_ball_tree_exited() -> void:
	_unlock_after_play()

func _unlock_after_play() -> void:
	_current_ball = null
	_play_locked = false
	_charging = false
	_charge_t = 0.0
	_zoom_reset()
	if _fx:
		_fx.visible = false
		_fx.emitting = false
	# camera returns to default via GameCamera

# ---------------------- Camera juice ----------------------
func _apply_charge_zoom() -> void:
	if _cam == null:
		return
	var mul = max(1.0, charge_zoom_in_mul)                   # ensure zooms IN
	var eased := _ease_out(_charge_t)
	var target = _cam_zoom_base * lerp(1.0, mul, eased)
	_cam.zoom = target

func _zoom_reset() -> void:
	if _cam == null:
		return
	var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(_cam, "zoom", _cam_zoom_base, zoom_snap_time)

# ---------------------- FX drive ----------------------
func _update_charge_fx() -> void:
	if _fx == null:
		return
	var p_split = clamp(phase_split, 0.05, 0.95)
	var phase := 0
	var level := 0.0
	if _charge_t <= p_split:
		phase = 0
		level = clamp(_charge_t / p_split, 0.0, 1.0)
	else:
		phase = 1
		level = clamp((_charge_t - p_split) / (1.0 - p_split), 0.0, 1.0)
	_fx.set_level(level, phase)

# ---------------------- Math ----------------------
func _ease_out(x: float) -> float:
	var a = clamp(x, 0.0, 1.0)
	return 1.0 - (1.0 - a) * (1.0 - a)
