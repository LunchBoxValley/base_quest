extends Node2D
class_name Ball

signal out_of_play

@export var speed: float = 220.0
@export var max_travel: float = 200.0

# --- Spin (micro juice) ---
@export_group("Spin")
@export var spin_fps: float = 18.0
@export var anim_speed_scale: float = 1.0

# --- Depth Scale — Pitch (mild) ---
@export_group("Depth Scale — Pitch")
@export var near_y_pitch: float = 140.0
@export var far_y_pitch: float = 60.0
@export var scale_near_pitch: float = 1.00
@export var scale_far_pitch: float = 0.50

# --- Depth Scale — Hit (bold NES-y) ---
@export_group("Depth Scale — Hit")
@export var near_y_hit: float = 140.0
@export var far_y_hit: float = 20.0
@export var scale_near_hit: float = 1.15
@export var scale_far_hit: float = 0.30
@export var hit_initial_shrink: float = 0.70
@export var hit_depth_boost_time: float = 0.22

# --- Quantize to keep pixels crisp ---
@export_group("Depth Quantize")
@export var scale_quantize_step: float = 0.125

# --- Trail (juice) ---
@export_group("Trail")
@export var trail_len: int = 8

# --- Grounder / Drop tuning (no full physics) ---
@export_group("Grounder / Drop")
@export var bounce_count_min: int = 1
@export var bounce_count_max: int = 3
@export var bounce_spacing_px_min: float = 28.0
@export var bounce_spacing_px_max: float = 52.0
@export var bounce_speed_mul: float = 0.82
@export var drop_trigger_px: float = 44.0
@export var drop_speed_mul: float = 0.60
@export var drop_bounces: int = 1
@export var roll_friction: float = 80.0
@export var stop_speed_threshold: float = 30.0

# --- Shadow control (smaller + slide down-left with "height") ---
@export_group("Shadow")
@export var shadow_enabled: bool = true
@export var shadow_radius_min_px: float = 0.8     # very small when “high”
@export var shadow_radius_max_px: float = 3.0     # modest near ground
@export var shadow_alpha_near: float = 0.70       # opaque near ground
@export var shadow_alpha_far: float = 0.18        # faint when high
@export var shadow_width_scale: float = 1.2       # ellipse proportions
@export var shadow_height_scale: float = 0.4
@export var shadow_y_offset: float = 0.0
@export var shadow_slide_per_height_px: float = 2.0  # slide distance per “height”
@export var shadow_dir: Vector2 = Vector2(-1.0, 1.0) # ← light from upper-right → shadow down-left
@export var shadow_base_offset: Vector2 = Vector2(-3.0, 2.0) # sits slightly left & behind even at h=0

# --- State ---
var _velocity: Vector2 = Vector2.ZERO
var _active: bool = false
var _start_pos: Vector2 = Vector2.ZERO
var _is_hit: bool = false

# Delivery flag: "pitch" | "hit" | "throw"
var _delivery: String = "pitch"

# Contact kind
const KIND_GROUNDER := 0
const KIND_LINER    := 1
const KIND_FLY      := 2
const KIND_BLAST    := 3
var _kind: int = KIND_LINER

# Bounce / drop state
var _distance_traveled: float = 0.0
var _last_bounce_at: float = 0.0
var _next_bounce_spacing: float = 40.0
var _bounces_left: int = 0
var _in_roll: bool = false
var _dropped: bool = false

# Node refs (optional)
@onready var anim: AnimatedSprite2D = $Anim
@onready var sprite: Sprite2D = $Sprite
@onready var trail: Line2D = $Trail
@onready var shadow := $Shadow    # BallShadow (optional child)

var _spin_t: float = 0.0
var _spin_active: bool = false
var _hit_boost_t: float = 0.0

func _ready() -> void:
	visible = false
	
	
	add_to_group("balls")
	
	if trail:
		trail.top_level = true
		trail.default_color = Color(1, 1, 1, 0.6)
		trail.clear_points()
	if shadow:
		shadow.z_index = -1
		shadow.scale = Vector2(shadow_width_scale, shadow_height_scale)
		shadow.position = shadow_base_offset + Vector2(0, shadow_y_offset)

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	_reset_state()
	global_position = start_global
	_start_pos = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	_is_hit = false
	_delivery = "pitch"
	visible = true
	_start_spin()
	_update_depth_scale()
	_update_shadow()
	if trail:
		trail.clear_points()
		trail.add_point(global_position)

# meta can include: {"type": "grounder"/"liner"/"fly"/"blast", "angle_deg": float}
func deflect(direction: Vector2, new_speed: float, meta: Dictionary = {}) -> void:
	_reset_state()
	_is_hit = true
	_delivery = "hit"
	_start_pos = global_position
	_hit_boost_t = hit_depth_boost_time
	_velocity = direction.normalized() * new_speed
	visible = true
	_start_spin()

	var label := String(meta.get("type", "liner"))
	if label == "grounder":
		_kind = KIND_GROUNDER
	elif label == "fly":
		_kind = KIND_FLY
	elif label == "blast":
		_kind = KIND_BLAST
	else:
		_kind = KIND_LINER

	if _kind == KIND_GROUNDER:
		_bounces_left = bounce_count_min + (randi() % max(1, bounce_count_max - bounce_count_min + 1))
		_next_bounce_spacing = randf_range(bounce_spacing_px_min, bounce_spacing_px_max)
	else:
		_bounces_left = 0
		_next_bounce_spacing = 99999.0

	if trail:
		trail.clear_points()
		trail.add_point(global_position)

	_update_depth_scale()
	_update_shadow()

func mark_thrown() -> void:
	_delivery = "throw"

func last_delivery() -> String:
	return _delivery

func _reset_state() -> void:
	_distance_traveled = 0.0
	_last_bounce_at = 0.0
	_in_roll = false
	_dropped = false
	_bounces_left = 0
	_spin_t = 0.0
	_spin_active = false
	_hit_boost_t = 0.0

func _start_spin() -> void:
	if anim and anim.sprite_frames:
		var frames := anim.sprite_frames
		var names := frames.get_animation_names()
		if names.size() > 0:
			if names.has("spin"):
				anim.animation = "spin"
			else:
				anim.animation = names[0]
			anim.speed_scale = anim_speed_scale
			anim.play()
			_spin_active = false
			return
	_spin_t = 0.0
	_spin_active = true

func _stop_spin() -> void:
	if anim:
		anim.stop()
	_spin_active = false
	if sprite:
		sprite.rotation = 0.0

func _process(delta: float) -> void:
	if _spin_active and sprite:
		_spin_t += delta * spin_fps
		var idx := int(_spin_t) % 4
		sprite.rotation = float(idx) * 0.5 * PI
	if _hit_boost_t > 0.0:
		_hit_boost_t -= delta
	_update_depth_scale()
	_update_shadow()

func _physics_process(delta: float) -> void:
	if not _active:
		return

	var step := _velocity * delta
	global_position += step
	_distance_traveled += step.length()

	# Late outfield drop for air balls
	if _is_hit and not _dropped and _kind != KIND_GROUNDER:
		var remaining := max_travel - _distance_traveled
		if remaining <= drop_trigger_px:
			_do_drop()

	# Grounder scheduled bounces
	if _is_hit and _kind == KIND_GROUNDER and _bounces_left > 0:
		var since := _distance_traveled - _last_bounce_at
		if since >= _next_bounce_spacing:
			_do_bounce()

	# Trail update
	if trail:
		trail.add_point(global_position)
		while trail.get_point_count() > trail_len:
			trail.remove_point(0)

	# Roll friction deceleration
	if _in_roll:
		var spd := _velocity.length()
		spd = max(0.0, spd - roll_friction * delta)
		if spd <= stop_speed_threshold:
			_end_play()
			return
		_velocity = _velocity.normalized() * spd

	# End by distance
	if _distance_traveled >= max_travel and not _in_roll:
		_end_play()

func _do_bounce() -> void:
	_last_bounce_at = _distance_traveled
	_next_bounce_spacing = randf_range(bounce_spacing_px_min, bounce_spacing_px_max)
	_bounces_left -= 1
	_velocity *= bounce_speed_mul
	_pulse_scale(1.10, 0.08)
	_update_shadow()
	if _bounces_left <= 0:
		_in_roll = true

func _do_drop() -> void:
	_dropped = true
	_velocity *= drop_speed_mul
	_pulse_scale(1.12, 0.10)
	_update_shadow()
	if drop_bounces > 0:
		_bounces_left = drop_bounces
		_last_bounce_at = _distance_traveled
		_next_bounce_spacing = 12.0
	_in_roll = true

func _pulse_scale(amount: float, time_s: float) -> void:
	var start := scale
	scale = start * amount
	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "scale", start, time_s)

func _end_play() -> void:
	_active = false
	_stop_spin()
	out_of_play.emit()
	queue_free()

func _update_depth_scale() -> void:
	var near_y := near_y_hit if _is_hit else near_y_pitch
	var far_y :=  far_y_hit  if _is_hit else far_y_pitch
	var s_near := scale_near_hit if _is_hit else scale_near_pitch
	var s_far :=  scale_far_hit  if _is_hit else scale_far_pitch

	var t = clamp(inverse_lerp(far_y, near_y, global_position.y), 0.0, 1.0)
	var s = lerp(s_far, s_near, t)

	if _is_hit and hit_depth_boost_time > 0.0:
		var k = clamp(_hit_boost_t / hit_depth_boost_time, 0.0, 1.0)
		var factor = lerp(1.0, hit_initial_shrink, k)
		s *= factor

	if scale_quantize_step > 0.0:
		s = round(s / scale_quantize_step) * scale_quantize_step

	scale = Vector2.ONE * max(0.01, s)

# ---------- Shadow logic ----------
func _estimate_height_norm() -> float:
	# 0..1 where 0 = on ground, 1 = peak. Crude but readable.
	if not _is_hit:
		return 0.0
	if _in_roll or _dropped:
		return 0.0

	var air_len = max(1.0, max_travel - drop_trigger_px)
	var u: float
	if _kind == KIND_GROUNDER:
		var since := _distance_traveled - _last_bounce_at
		var seg = max(1.0, _next_bounce_spacing)
		u = clamp(since / seg, 0.0, 1.0)
	else:
		u = clamp(_distance_traveled / air_len, 0.0, 1.0)

	var hump := 4.0 * u * (1.0 - u)   # 0..1 with peak at u=0.5
	var k := 0.5
	if _kind == KIND_GROUNDER:
		k = 0.15
	elif _kind == KIND_LINER:
		k = 0.45
	elif _kind == KIND_FLY:
		k = 0.80
	elif _kind == KIND_BLAST:
		k = 1.00

	return clamp(hump * k, 0.0, 1.0)

func _update_shadow() -> void:
	if not shadow_enabled or shadow == null:
		return

	var h := _estimate_height_norm()  # 0..1 (0 = ground, 1 = “high”)

	# Smaller + fainter as “height” increases
	var radius = lerp(shadow_radius_max_px, shadow_radius_min_px, h)
	var alpha  = lerp(shadow_alpha_near,    shadow_alpha_far,    h)

	if shadow.has_method("set_shape"):
		shadow.set_shape(radius, alpha)

	# Keep ellipse proportions
	shadow.scale = Vector2(shadow_width_scale, shadow_height_scale)

	# Directional slide: down-left (if shadow_dir = (-1, +1)) as height increases
	var dir := shadow_dir
	if dir.length() > 0.001:
		dir = dir.normalized()
	var slide := dir * shadow_slide_per_height_px * h

	# Base placement: slightly left & behind even at h=0
	shadow.position = shadow_base_offset + Vector2(0, shadow_y_offset) + slide
	shadow.z_index = -1
