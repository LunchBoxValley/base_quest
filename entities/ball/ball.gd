extends Node2D
class_name Ball

signal out_of_play
signal wall_hit(normal: Vector2)

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

# --- Height Scaling for sprite (visual “pop”) ---
@export_group("Height Scaling")
@export var height_scale_ground: float = 0.90   # smaller when hugging dirt
@export var height_scale_high: float = 6.00     # ~6x at apex

# --- Quantize to keep pixels crisp ---
@export_group("Depth Quantize")
@export var scale_quantize_step: float = 0.125

# --- Trail (juice) ---
@export_group("Trail")
@export var trail_len: int = 8

# --- Grounder / Drop tuning (surface behavior) ---
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

# --- Shadow control ---
@export_group("Shadow")
@export var shadow_enabled: bool = true
@export var shadow_radius_min_px: float = 0.5
@export var shadow_radius_max_px: float = 5.0
@export var shadow_alpha_near: float = 0.75
@export var shadow_alpha_far: float = 0.12
@export var shadow_width_scale: float = 1.2
@export var shadow_height_scale: float = 0.4
@export var shadow_y_offset: float = 0.0
@export var shadow_slide_per_height_px: float = 2.0
@export var shadow_dir: Vector2 = Vector2(-1.0, 1.0)
@export var shadow_base_offset: Vector2 = Vector2(-3.0, 2.0)

# --- Optional Sweep (ShapeCast2D) ---
@export_group("Sweep (optional)")
@export var sweep_enable_speed: float = 220.0
@export var sweep_epsilon: float = 0.5

# --- NEW: Simple Z-Arc (vertical) ---
@export_group("Z Arc")
@export var g_px_s2: float = 400.0              # gravity in "px per sec^2" for z axis
@export var apex_grounder_px: float = 2.0       # approximate apex heights by type
@export var apex_liner_px: float = 10.0
@export var apex_fly_px: float = 24.0
@export var apex_blast_px: float = 36.0
@export var hr_height_multiplier: float = 1.0   # power-up friendly: scales clearance height

# --- NEW: Inspector Power-Hit debug (easy dinger testing) ---
@export_group("Debug / Power Hit")
@export var debug_power_hit: bool = false           # when true, all hits use boosted apex
@export var debug_power_multiplier: float = 2.0     # scales apex height for hits
@export var debug_force_air: bool = true            # ensure even “grounders” get some air when power is on
@export var debug_min_air_px: float = 16.0          # minimum apex when power is on (helps clear 12px wall)

# --- State ---
var _velocity: Vector2 = Vector2.ZERO
var _active: bool = false
var _start_pos: Vector2 = Vector2.ZERO
var _is_hit: bool = false

# Z state
var _z: float = 0.0
var _vz: float = 0.0
var _airborne: bool = false

# Delivery flag: "pitch" | "hit" | "throw"
var _delivery: String = "pitch"

# Contact kind
const KIND_GROUNDER := 0
const KIND_LINER := 1
const KIND_FLY := 2
const KIND_BLAST := 3
var _kind: int = KIND_LINER

# Bounce / drop state (2D travel bookkeeping)
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
@onready var shadow := $Shadow
@onready var _sweep: ShapeCast2D = get_node_or_null("Sweep")

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
	if _sweep:
		_sweep.enabled = false

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

# meta: {"type":"grounder"/"liner"/"fly"/"blast", "delivery":"hit"/"throw"/"pitch", ...}
func deflect(direction: Vector2, new_speed: float, meta: Dictionary = {}) -> void:
	_reset_state()
	var delivery := String(meta.get("delivery", "hit")).to_lower()
	match delivery:
		"throw":
			_delivery = "throw"; _is_hit = false
		"pitch":
			_delivery = "pitch"; _is_hit = false
		_:
			_delivery = "hit";   _is_hit = true

	_start_pos = global_position
	_hit_boost_t = hit_depth_boost_time
	_velocity = direction.normalized() * new_speed
	visible = true
	_start_spin()

	# Kind set
	var label := String(meta.get("type", "liner"))
	if label == "grounder":
		_kind = KIND_GROUNDER
	elif label == "fly":
		_kind = KIND_FLY
	elif label == "blast":
		_kind = KIND_BLAST
	else:
		_kind = KIND_LINER

	# Z-arc only for actual hits (not throws/pitches)
	if _is_hit:
		var H := _apex_for_kind()

		# Power-Hit debug: multiply apex and ensure a minimum air if desired
		if debug_power_hit:
			H *= max(1.0, debug_power_multiplier)
			if debug_force_air:
				H = max(H, debug_min_air_px)

		# Z kinematics: H = vz^2 / (2g)  ->  vz = sqrt(2 g H)
		_vz = sqrt(max(0.0, 2.0 * g_px_s2 * H))
		_z = 0.0
		_airborne = _vz > 0.0
	else:
		_vz = 0.0
		_z = 0.0
		_airborne = false

	# Grounder/liner 2D bounce scheduling as before
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

func mark_thrown() -> void: _delivery = "throw"
func last_delivery() -> String: return _delivery

func _reset_state() -> void:
	_distance_traveled = 0.0
	_last_bounce_at = 0.0
	_in_roll = false
	_dropped = false
	_bounces_left = 0
	_spin_t = 0.0
	_spin_active = false
	_hit_boost_t = 0.0
	_z = 0.0
	_vz = 0.0
	_airborne = false

func _start_spin() -> void:
	if anim and anim.sprite_frames:
		var frames := anim.sprite_frames
		var names := frames.get_animation_names()
		if names.size() > 0:
			anim.animation = "spin" if names.has("spin") else names[0]
			anim.speed_scale = anim_speed_scale
			anim.play()
			_spin_active = false
			return
	_spin_t = 0.0
	_spin_active = true

func _stop_spin() -> void:
	if anim: anim.stop()
	_spin_active = false
	if sprite: sprite.rotation = 0.0

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
	if not _active: return
	var step := _velocity * delta

	# Optional swept motion
	if _sweep and _velocity.length() >= sweep_enable_speed and step.length() > 0.0:
		_sweep.enabled = true
		_sweep.target_position = step
		_sweep.force_shapecast_update()
		if _sweep.is_colliding():
			var p := _sweep.get_collision_point(0)
			var to_hit := p - global_position
			var d := to_hit.length()
			var move_vec := step
			if d < step.length():
				var safe_d = max(0.0, d - sweep_epsilon)
				move_vec = to_hit.normalized() * safe_d if safe_d > 0.0 else Vector2.ZERO
			global_position += move_vec
		else:
			global_position += step
	else:
		if _sweep: _sweep.enabled = false
		global_position += step

	_distance_traveled += step.length()

	# Z update (1D vertical)
	if _airborne:
		_vz -= g_px_s2 * delta
		_z += _vz * delta
		if _z <= 0.0:
			_z = 0.0
			_airborne = false

	# Late outfield drop for air balls (2D pacing kept)
	if _is_hit and not _dropped and _kind != KIND_GROUNDER:
		var remaining := max_travel - _distance_traveled
		if remaining <= drop_trigger_px:
			_do_drop()

	# Grounder scheduled bounces (2D)
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

# ---------- Depth & Shadow ----------
func _update_depth_scale() -> void:
	# Base distance-from-camera scale by y
	var near_y := near_y_hit if _is_hit else near_y_pitch
	var far_y := far_y_hit if _is_hit else far_y_pitch
	var s_near := scale_near_hit if _is_hit else scale_near_pitch
	var s_far := scale_far_hit if _is_hit else scale_far_pitch
	var t = clamp(inverse_lerp(far_y, near_y, global_position.y), 0.0, 1.0)
	var s = lerp(s_far, s_near, t)

	# Early hit shrink
	if _is_hit and hit_depth_boost_time > 0.0:
		var k = clamp(_hit_boost_t / hit_depth_boost_time, 0.0, 1.0)
		s *= lerp(1.0, hit_initial_shrink, k)

	# Z-based visual pop
	var hn := get_height_norm()
	var z_scale = lerp(height_scale_ground, height_scale_high, hn)
	s *= z_scale

	if scale_quantize_step > 0.0:
		s = round(s / scale_quantize_step) * scale_quantize_step
	scale = Vector2.ONE * max(0.01, s)

func _update_shadow() -> void:
	if not shadow_enabled or shadow == null:
		return
	var hn := get_height_norm()
	var radius = lerp(shadow_radius_max_px, shadow_radius_min_px, hn)
	var alpha = lerp(shadow_alpha_near, shadow_alpha_far, hn)
	if shadow.has_method("set_shape"):
		shadow.set_shape(radius, alpha)
	shadow.scale = Vector2(shadow_width_scale, shadow_height_scale)
	var dir := shadow_dir
	if dir.length() > 0.001: dir = dir.normalized()
	var slide := dir * shadow_slide_per_height_px * hn
	shadow.position = shadow_base_offset + Vector2(0, shadow_y_offset) + slide
	shadow.z_index = -1

# ---------- Z helpers ----------
func _apex_for_kind() -> float:
	match _kind:
		KIND_GROUNDER: return apex_grounder_px
		KIND_LINER:    return apex_liner_px
		KIND_FLY:      return apex_fly_px
		KIND_BLAST:    return apex_blast_px
		_:             return apex_liner_px

func get_height_px() -> float:
	# Actual current z height in "pixels", scaled by power-up multiplier
	return max(0.0, _z) * max(0.0, hr_height_multiplier)

func get_height_norm() -> float:
	var Hmax = max(0.001, _apex_for_kind()) * max(0.0, hr_height_multiplier)
	return clamp(get_height_px() / Hmax, 0.0, 1.0)

# ---------- Wall Bounce ----------
func wall_bounce(normal: Vector2, damping: float = 0.85, random_angle_deg: float = 12.0) -> void:
	if normal.length() <= 0.0001:
		return
	var n := normal.normalized()
	var v := _velocity
	# Reflect velocity over the wall normal (z unaffected by vertical wall)
	var r := v - 2.0 * v.dot(n) * n
	var ang := deg_to_rad(randf_range(-random_angle_deg, random_angle_deg))
	r = r.rotated(ang)
	_velocity = r * clamp(damping, 0.0, 1.0)

	# Keep it "in air" if it was; wall doesn't kill z
	_is_hit = true
	if _delivery != "throw":
		_delivery = "hit"

	wall_hit.emit(n)
	_pulse_scale(1.06, 0.06)
	_update_shadow()
