# res://entities/batter.gd
extends Node2D
class_name Batter

signal hit

@export var home_plate_path: NodePath
@export var swing_window: float = 0.12
@export var sweet_spot_phase: float = 0.5
@export var sweet_width: float = 0.30
@export var hit_radius_px: float = 8.0

# Baseline exit speed (px/s) at timing_quality=0.5; scaled per profile
@export var contact_speed_base: float = 260.0
@export var power_stat: float = 1.0

# How much timing shifts the ball left/right
@export var timing_side_gain: float = 0.6
# Random horizontal spray at poor timing (shrinks at good timing)
@export var spray_random: float = 0.18

# --- Profile angle bands (degrees) ---
@export_group("Launch Angle Bands (deg)")
@export var angle_grounder: Vector2 = Vector2(-5.0,  8.0)
@export var angle_liner:   Vector2 = Vector2( 8.0, 20.0)
@export var angle_fly:     Vector2 = Vector2(20.0, 35.0)
@export var angle_blast:   Vector2 = Vector2(28.0, 42.0)

# --- Exit speed multipliers per band ---
@export_group("Exit Speed Multipliers")
@export var ev_mul_grounder: Vector2 = Vector2(0.75, 0.95)
@export var ev_mul_liner:    Vector2 = Vector2(0.90, 1.10)
@export var ev_mul_fly:      Vector2 = Vector2(0.95, 1.20)
@export var ev_mul_blast:    Vector2 = Vector2(1.10, 1.35)

# --- Travel distances (px) ---
@export_group("Travel Distance (px)")
@export var travel_grounder: Vector2 = Vector2(120.0, 190.0)   # tends to stay infield
@export var travel_liner:    Vector2 = Vector2(200.0, 280.0)   # shallow/mid outfield
@export var travel_fly:      Vector2 = Vector2(260.0, 360.0)   # deeper outfield
@export var travel_blast:    Vector2 = Vector2(340.0, 460.0)   # HR-capable if fair

# --- Foul (fixed probability) ---
@export_group("Foul")
@export var foul_chance_on_contact: float = 0.05   # 5% on any contact

# --- Anti-instant-foul guards (tweak here if needed) ---
@export_group("Anti-Foul Guards")
@export var center_pull: float = 0.20              # 0..1 pull toward center on contact
@export var non_foul_side_scale: float = 0.55      # cap sideways push on non-fouls
@export var min_upward_for_fair: float = 0.25      # ensures the ball goes forward out of the wedge

# Contact point offset from plate (visual placement)
@export var bat_offset: Vector2 = Vector2(0, -2)

@onready var sprite: AnimatedSprite2D = $Sprite
var _plate: Node2D
var _swing_t: float = 0.0
var _did_contact: bool = false

func _ready() -> void:
	_plate = get_node_or_null(home_plate_path)
	if not InputMap.has_action("swing"):
		InputMap.add_action("swing")
		var ev := InputEventKey.new()
		ev.keycode = KEY_X
		InputMap.action_add_event("swing", ev)
	set_physics_process(true)

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("swing"):
		_swing_t = swing_window
		_did_contact = false
		_play_swing_pose()

func _physics_process(delta: float) -> void:
	if _swing_t > 0.0:
		_swing_t -= delta
		if not _did_contact:
			_check_contact()
	else:
		_reset_pose()

func _contact_point() -> Vector2:
	var base := (_plate.global_position if is_instance_valid(_plate) else global_position)
	return base + bat_offset

func _check_contact() -> void:
	var p := _contact_point()
	var min_y := (_plate.global_position.y - 10.0) if is_instance_valid(_plate) else (global_position.y - 10.0)
	var max_y := (_plate.global_position.y + 6.0)  if is_instance_valid(_plate) else (global_position.y + 6.0)

	for node in get_tree().get_nodes_in_group("balls"):
		if not (node is Ball): continue
		var b := node as Ball
		var pos := b.global_position
		if pos.y >= min_y and pos.y <= max_y and pos.distance_to(p) <= hit_radius_px:
			_did_contact = true
			_on_contact(b, p)
			break

func _on_contact(ball: Ball, hitpos: Vector2) -> void:
	# Timing quality 0..1 (1 best)
	var phase = 1.0 - clamp(_swing_t / max(0.0001, swing_window), 0.0, 1.0)
	var offset = phase - sweet_spot_phase
	var norm = clamp(abs(offset) / max(0.0001, sweet_width), 0.0, 1.0)
	var q = 1.0 - norm  # timing_quality

	# Left/right tendency from where we hit + timing phase
	var plate_x := (_plate.global_position.x if is_instance_valid(_plate) else global_position.x)
	var point_bias = clamp((hitpos.x - plate_x) / 12.0, -1.0, 1.0)
	var timing_bias = clamp(offset / max(0.0001, sweet_width), -1.0, 1.0) * timing_side_gain

	# Random spray shrinks with quality
	var spray = randf_range(-spray_random, spray_random) * (1.0 - q)
	var side_mix = clamp(point_bias + timing_bias + spray, -1.0, 1.0)

	# Gentle pull toward center to avoid instant wedge exit near home
	side_mix = lerp(side_mix, 0.0, clamp(center_pull, 0.0, 1.0))

	# Decide a contact profile
	var profile := _sample_contact_profile(q)

	# 5% foul chance on contact
	var force_foul = randf() < clamp(foul_chance_on_contact, 0.0, 1.0)

	# Build direction from launch angle and side bias
	var angle_deg := randf_range(profile.angle_range.x, profile.angle_range.y)
	var rad := deg_to_rad(angle_deg)
	var up := sin(rad)
	var side_mag = max(0.2, cos(rad))
	var side_sign := 1.0 if side_mix >= 0.0 else -1.0
	var side_amount = abs(side_mix)            # how “left/right” the hit wants to be

	if force_foul:
		# Make it clearly foul: hard sideways, less upward so it peels fast
		side_mag = 1.0
		up = max(0.12, up * 0.5)
	else:
		# Keep variety, but keep it fair early: cap sideways push and ensure forward momentum
		side_mag *= non_foul_side_scale * lerp(0.7, 1.0, q)
		up = clamp(up, min_upward_for_fair, 1.0)

	var dir := Vector2(side_sign * side_mag * side_amount, -up).normalized()

	# Exit speed
	var ev_mul := randf_range(profile.ev_mul.x, profile.ev_mul.y)
	var ev = contact_speed_base * ev_mul * lerp(0.8, 1.2, q) * clamp(power_stat, 0.5, 1.6)

	# Travel distance
	var travel := randf_range(profile.travel_px.x, profile.travel_px.y)
	travel *= lerp(0.9, 1.15, q)

	# Launch!
	ball.deflect(dir, ev)
	ball.max_travel = max(ball.max_travel, travel)

	# Juice
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(2.0, 0.12)

	hit.emit()
	Juice.hitstop(0.06)

	var judge := get_tree().get_first_node_in_group("field_judge")
	if judge and judge.has_method("track_batted_ball"):
		judge.track_batted_ball(ball)

func _sample_contact_profile(q: float) -> Dictionary:
	if q < 0.25:
		return {"angle_range": angle_grounder, "ev_mul": ev_mul_grounder, "travel_px": travel_grounder}
	elif q < 0.55:
		return {"angle_range": angle_liner,   "ev_mul": ev_mul_liner,   "travel_px": travel_liner}
	elif q < 0.85:
		return {"angle_range": angle_fly,     "ev_mul": ev_mul_fly,     "travel_px": travel_fly}
	else:
		var t = clamp((q - 0.70) / 0.30, 0.0, 1.0)
		var blast_p = lerp(0.08, 0.22, t)
		var use_blast = randf() < blast_p
		if use_blast:
			return {"angle_range": angle_blast, "ev_mul": ev_mul_blast, "travel_px": travel_blast}
		else:
			return {"angle_range": angle_fly,   "ev_mul": ev_mul_fly,   "travel_px": travel_fly}

func _play_swing_pose() -> void:
	if sprite:
		sprite.rotation = deg_to_rad(-18)

func _reset_pose() -> void:
	if sprite:
		if abs(sprite.rotation) > 0.001:
			sprite.rotation = lerp(sprite.rotation, 0.0, 0.35)
		else:
			sprite.rotation = 0.0
