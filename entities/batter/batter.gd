extends Node2D
class_name Batter

signal hit

@export var input_enabled: bool = true
@export var home_plate_path: NodePath

@export var swing_window: float = 0.12
@export var sweet_spot_phase: float = 0.5
@export var sweet_width: float = 0.30
@export var hit_radius_px: float = 8.0

@export var contact_speed_base: float = 245.0  # global EV nerf
@export var power_stat: float = 1.0
@export var timing_side_gain: float = 0.55
@export var spray_random: float = 0.18

@export_group("Launch Angle Bands (deg)")
@export var angle_grounder: Vector2 = Vector2(-8.0, 6.0)
@export var angle_liner:   Vector2 = Vector2( 6.0, 16.0)
@export var angle_fly:     Vector2 = Vector2(16.0, 24.0)
@export var angle_blast:   Vector2 = Vector2(24.0, 30.0)  # quite stingy
@export var angle_pop:     Vector2 = Vector2(32.0, 46.0)  # pop-up: high, shallow

@export_group("Exit Speed Multipliers")
@export var ev_mul_grounder: Vector2 = Vector2(0.70, 0.90)
@export var ev_mul_liner:   Vector2 = Vector2(0.82, 0.96)
@export var ev_mul_fly:     Vector2 = Vector2(0.86, 1.00)
@export var ev_mul_blast:   Vector2 = Vector2(1.02, 1.12) # big nerf
@export var ev_mul_pop:     Vector2 = Vector2(0.55, 0.80) # soft pop

@export_group("Travel Distance (px)")
@export var travel_grounder: Vector2 = Vector2(110.0, 170.0)
@export var travel_liner:   Vector2 = Vector2(170.0, 230.0)
@export var travel_fly:     Vector2 = Vector2(205.0, 275.0)
@export var travel_blast:   Vector2 = Vector2(300.0, 360.0) # HRs now rare
@export var travel_pop:     Vector2 = Vector2(120.0, 175.0) # infield floaters

@export_group("Foul")
@export var foul_chance_on_contact: float = 0.12

@export_group("Anti-Foul / Fairness Shaping")
@export var center_pull: float = 0.28
@export var non_foul_side_scale: float = 0.40
@export var min_upward_for_fair: float = 0.16
@export var outfield_min_travel_px: float = 220.0

@export var bat_offset: Vector2 = Vector2(0, -2)

@export_group("Input Influence")
@export var bat_input_bias_scale: float = 0.30
@export var input_effect_scale: float = 0.10

# --- Settable by CPU ---
var _ai_lr := 0.0
var _ai_pop_prob := 0.0

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

func _unhandled_input(_event: InputEvent) -> void:
	if not input_enabled:
		return
	if Input.is_action_just_pressed("swing"):
		_trigger_swing()

func _physics_process(delta: float) -> void:
	if _swing_t > 0.0:
		_swing_t -= delta
		if not _did_contact:
			_check_contact()
	else:
		_reset_pose()

func _contact_point() -> Vector2:
	var base := global_position
	if is_instance_valid(_plate):
		base = _plate.global_position
	return base + bat_offset

func _check_contact() -> void:
	var p := _contact_point()
	var min_y := p.y - 10.0
	var max_y := p.y + 6.0
	for node in get_tree().get_nodes_in_group("balls"):
		if not (node is Ball):
			continue
		var b := node as Ball
		var pos := b.global_position
		if pos.y >= min_y and pos.y <= max_y and pos.distance_to(p) <= hit_radius_px:
			_did_contact = true
			_on_contact(b, p)
			break

func _trigger_swing() -> void:
	_swing_t = swing_window
	_did_contact = false
	_play_swing_pose()

# -------- PUBLIC AI API --------
func ai_set_lr_bias(lr: float) -> void:
	_ai_lr = clamp(lr, -1.0, 1.0)

func ai_set_contact_pop_prob(p: float) -> void:
	_ai_pop_prob = clamp(p, 0.0, 1.0)

func ai_swing_after(seconds: float) -> void:
	var t := get_tree().create_timer(max(0.01, seconds))
	t.timeout.connect(_trigger_swing)

# -------- Contact & outcome --------
func _on_contact(ball: Ball, hitpos: Vector2) -> void:
	ball.set_meta("batted", true)
	if has_node("BatSwoosh"): $BatSwoosh.fire()

	# Timing quality 0..1 (1 = perfect)
	var phase = 1.0 - clamp(_swing_t / max(0.0001, swing_window), 0.0, 1.0)
	var offset = phase - sweet_spot_phase
	var norm = clamp(abs(offset) / max(0.0001, sweet_width), 0.0, 1.0)
	var q = 1.0 - norm

	# L/R bias blend: location + timing + spray + input/AI
	var plate_x := (_plate.global_position.x if is_instance_valid(_plate) else global_position.x)
	var point_bias = clamp((hitpos.x - plate_x) / 12.0, -1.0, 1.0)
	var timing_bias = clamp(offset / max(0.0001, sweet_width), -1.0, 1.0) * timing_side_gain
	var spray = randf_range(-spray_random, spray_random) * (1.0 - q)
	var side_mix = clamp(point_bias + timing_bias + spray, -1.0, 1.0)
	side_mix = lerp(side_mix, 0.0, clamp(center_pull, 0.0, 1.0))

	var lr_input := 0.0
	if input_enabled:
		lr_input = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	var lr := lr_input + _ai_lr

	var q_boost = lerp(0.5, 0.95, q)
	side_mix = clamp(side_mix + lr * bat_input_bias_scale * clamp(input_effect_scale, 0.0, 1.0) * q_boost, -1.0, 1.0)

	# Profile selection (CPU can bias to pop)
	var profile := _sample_contact_profile(q)

	# Foul chance
	var force_foul = (randf() < clamp(foul_chance_on_contact, 0.0, 0.18))

	# Angle
	var angle_deg := randf_range(profile.angle_range.x, profile.angle_range.y)
	var rad := deg_to_rad(angle_deg)
	var up := sin(rad)
	var side_mag = max(0.2, cos(rad))
	var side_sign := (-1.0 if side_mix < 0.0 else 1.0)
	var side_amount = abs(side_mix)

	if force_foul:
		side_mag = 1.0
		up = max(0.12, up * 0.5)
	else:
		side_mag *= non_foul_side_scale * lerp(0.60, 0.92, q)
		up = clamp(up, min_upward_for_fair, 1.0)

	var dir := Vector2(side_sign * side_mag * side_amount, -up).normalized()

	# Exit velo & travel
	var ev_mul := randf_range(profile.ev_mul.x, profile.ev_mul.y)
	var ev = contact_speed_base * ev_mul * lerp(0.78, 1.06, q) * clamp(power_stat, 0.5, 1.25)

	var travel := randf_range(profile.travel_px.x, profile.travel_px.y)
	travel *= lerp(0.90, 1.06, q)

	var meta := {"label": profile.label, "type": profile.label, "angle_deg": angle_deg}

	var argc := _get_method_argc(ball, "deflect")
	if argc >= 3: ball.call("deflect", dir, ev, meta)
	else:         ball.call("deflect", dir, ev)

	ball.max_travel = max(ball.max_travel, travel)

	if not force_foul:
		GameManager.call_hit(false)

	# Camera / judge hooks
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam:
		if cam.has_method("kick"): cam.kick(1.6, 0.10)
		if cam.has_method("follow_target"): cam.follow_target(ball, true)
	var judge := get_tree().get_first_node_in_group("field_judge")
	if judge and judge.has_method("track_batted_ball"):
		judge.track_batted_ball(ball)

	hit.emit()

func _get_method_argc(obj: Object, name: String) -> int:
	for m in obj.get_method_list():
		if String(m.get("name")) == name:
			var args = m.get("args")
			return (args as Array).size() if typeof(args) == TYPE_ARRAY else 0
	return 0

func _sample_contact_profile(q: float) -> Dictionary:
	# Occasional intentional pop-fly if CPU requested it
	if randf() < _ai_pop_prob:
		return {"label":"fly","angle_range":angle_pop,"ev_mul":ev_mul_pop,"travel_px":travel_pop}

	# Strong bias to grounders/liners; blasts are rare even at perfect timing
	if q < 0.40:
		return {"label":"grounder","angle_range":angle_grounder,"ev_mul":ev_mul_grounder,"travel_px":travel_grounder}
	elif q < 0.78:
		return {"label":"liner","angle_range":angle_liner,"ev_mul":ev_mul_liner,"travel_px":travel_liner}
	elif q < 0.95:
		return {"label":"fly","angle_range":angle_fly,"ev_mul":ev_mul_fly,"travel_px":travel_fly}
	else:
		var t = clamp((q - 0.95) / 0.05, 0.0, 1.0)
		var blast_p = lerp(0.008, 0.03, t)   # << super stingy
		blast_p *= clamp(0.70 + 0.30 * power_stat, 0.70, 1.05)
		if randf() < blast_p:
			return {"label":"blast","angle_range":angle_blast,"ev_mul":ev_mul_blast,"travel_px":travel_blast}
		return {"label":"fly","angle_range":angle_fly,"ev_mul":ev_mul_fly,"travel_px":travel_fly}

func _play_swing_pose() -> void:
	if sprite: sprite.rotation = deg_to_rad(-18)

func _reset_pose() -> void:
	if sprite:
		if abs(sprite.rotation) > 0.001:
			sprite.rotation = lerp(sprite.rotation, 0.0, 0.35)
		else:
			sprite.rotation = 0.0
