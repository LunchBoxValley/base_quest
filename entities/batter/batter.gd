extends Node2D
class_name Batter

signal hit

@export var home_plate_path: NodePath
@export var swing_window: float = 0.12
@export var sweet_spot_phase: float = 0.5
@export var sweet_width: float = 0.30
@export var hit_radius_px: float = 8.0

@export var contact_speed_base: float = 260.0
@export var power_stat: float = 1.0

@export var timing_side_gain: float = 0.6
@export var spray_random: float = 0.18

@export_group("Launch Angle Bands (deg)")
@export var angle_grounder: Vector2 = Vector2(-5.0,  8.0)
@export var angle_liner:   Vector2 = Vector2( 8.0, 20.0)
@export var angle_fly:     Vector2 = Vector2(20.0, 35.0)
@export var angle_blast:   Vector2 = Vector2(28.0, 42.0)

@export_group("Exit Speed Multipliers")
@export var ev_mul_grounder: Vector2 = Vector2(0.75, 0.95)
@export var ev_mul_liner:    Vector2 = Vector2(0.90, 1.10)
@export var ev_mul_fly:      Vector2 = Vector2(0.95, 1.20)
@export var ev_mul_blast:    Vector2 = Vector2(1.10, 1.35)

@export_group("Travel Distance (px)")
@export var travel_grounder: Vector2 = Vector2(120.0, 190.0)
@export var travel_liner:    Vector2 = Vector2(200.0, 280.0)
@export var travel_fly:      Vector2 = Vector2(260.0, 360.0)
@export var travel_blast:    Vector2 = Vector2(340.0, 460.0)

@export_group("Foul")
@export var foul_chance_on_contact: float = 0.05

@export_group("Anti-Foul Guards")
@export var center_pull: float = 0.20
@export var non_foul_side_scale: float = 0.55
@export var min_upward_for_fair: float = 0.25

@export var outfield_min_travel_px: float = 220.0
@export var bat_offset: Vector2 = Vector2(0, -2)

# ---------- Input Influence ----------
@export_group("Input Influence")
@export var bat_input_bias_scale: float = 0.35   # pre-scale bias amount
@export var input_effect_scale: float = 0.10     # NEW: 10% of prior strength

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

func _on_contact(ball: Ball, hitpos: Vector2) -> void:
	ball.set_meta("batted", true)

	var phase = 1.0 - clamp(_swing_t / max(0.0001, swing_window), 0.0, 1.0)
	var offset = phase - sweet_spot_phase
	var norm = clamp(abs(offset) / max(0.0001, sweet_width), 0.0, 1.0)
	var q = 1.0 - norm

	var plate_x := global_position.x
	if is_instance_valid(_plate):
		plate_x = _plate.global_position.x
	var point_bias = clamp((hitpos.x - plate_x) / 12.0, -1.0, 1.0)
	var timing_bias = clamp(offset / max(0.0001, sweet_width), -1.0, 1.0) * timing_side_gain
	var spray = randf_range(-spray_random, spray_random) * (1.0 - q)
	var side_mix = clamp(point_bias + timing_bias + spray, -1.0, 1.0)
	side_mix = lerp(side_mix, 0.0, clamp(center_pull, 0.0, 1.0))

	# --- Input nudges spray (INVERTED + 10% strength) ---
	# lr: Right = +1, Left = -1. Invert by negating it.
	var lr := Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	var q_boost = lerp(0.5, 1.0, q)  # better timing allows a touch more influence
	side_mix = clamp(
		side_mix + (-lr) * bat_input_bias_scale * clamp(input_effect_scale, 0.0, 1.0) * q_boost,
		-1.0, 1.0
	)

	var profile := _sample_contact_profile(q)
	var force_foul = randf() < clamp(foul_chance_on_contact, 0.0, 1.0)

	var angle_deg := randf_range(profile.angle_range.x, profile.angle_range.y)
	var rad := deg_to_rad(angle_deg)
	var up := sin(rad)
	var side_mag = max(0.2, cos(rad))
	var side_sign := 1.0
	if side_mix < 0.0:
		side_sign = -1.0
	var side_amount = abs(side_mix)

	if force_foul:
		side_mag = 1.0
		up = max(0.12, up * 0.5)
	else:
		side_mag *= non_foul_side_scale * lerp(0.7, 1.0, q)
		up = clamp(up, min_upward_for_fair, 1.0)

	var dir := Vector2(side_sign * side_mag * side_amount, -up).normalized()

	var ev_mul := randf_range(profile.ev_mul.x, profile.ev_mul.y)
	var ev = contact_speed_base * ev_mul * lerp(0.8, 1.2, q) * clamp(power_stat, 0.5, 1.6)

	var travel := randf_range(profile.travel_px.x, profile.travel_px.y)
	travel *= lerp(0.9, 1.15, q)

	var meta := {"label": profile.label, "type": profile.label, "angle_deg": angle_deg}

	var argc := _get_method_argc(ball, "deflect")
	if argc >= 3:
		ball.call("deflect", dir, ev, meta)
	elif argc >= 2:
		ball.call("deflect", dir, ev)
	else:
		ball.call("deflect", dir, ev)

	ball.max_travel = max(ball.max_travel, travel)

	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam:
		if cam.has_method("kick"):
			cam.kick(2.0, 0.12)
		if cam.has_method("follow_target"):
			cam.follow_target(ball, true)

	var hud := get_tree().get_first_node_in_group("umpire_hud")
	if hud:
		if force_foul:
			if hud.has_method("call_foul"):
				hud.call("call_foul")
		else:
			var is_hr = (profile.label == "blast")
			if is_hr and hud.has_method("call_home_run"):
				hud.call("call_home_run")
			elif hud.has_method("call_hit"):
				hud.call("call_hit")

	var is_hr2 = (profile.label == "blast")
	var is_outfield = (not force_foul) and (
		profile.label == "blast" or profile.label == "fly" or
		(profile.label == "liner" and travel >= outfield_min_travel_px)
	)

	if is_hr2 and cam:
		_set_ball_trail(ball, false)
		var tmr := Timer.new()
		tmr.one_shot = true
		tmr.wait_time = 0.12
		tmr.ignore_time_scale = true
		add_child(tmr)
		tmr.timeout.connect(func():
			_set_ball_trail(ball, true)
			if cam.has_method("hitstop"):
				cam.hitstop(0.07)
			if cam.has_method("hr_pan_out_and_back"):
				cam.hr_pan_out_and_back(0.95, 0.25, 0.18)
			tmr.queue_free()
		)
		tmr.start()
	elif is_outfield and cam:
		_set_ball_trail(ball, true)
		if cam.has_method("hitstop"):
			cam.hitstop(0.05)
	else:
		_set_ball_trail(ball, false)

	hit.emit()

	var judge := get_tree().get_first_node_in_group("field_judge")
	if judge and judge.has_method("track_batted_ball"):
		judge.track_batted_ball(ball)

func _set_ball_trail(ball: Node, on: bool) -> void:
	if ball == null:
		return
	var trail := ball.get_node_or_null("Trail")
	if trail and (trail is Line2D):
		(trail as Line2D).visible = on
		if not on:
			(trail as Line2D).clear_points()

func _get_method_argc(obj: Object, name: String) -> int:
	var list := obj.get_method_list()
	for m in list:
		var mname = m.get("name")
		if typeof(mname) == TYPE_STRING and String(mname) == name:
			var args = m.get("args")
			if typeof(args) == TYPE_ARRAY:
				return (args as Array).size()
			return 0
	return 0

func _sample_contact_profile(q: float) -> Dictionary:
	if q < 0.25:
		return {"label":"grounder", "angle_range": angle_grounder, "ev_mul": ev_mul_grounder, "travel_px": travel_grounder}
	elif q < 0.55:
		return {"label":"liner",    "angle_range": angle_liner,   "ev_mul": ev_mul_liner,   "travel_px": travel_liner}
	elif q < 0.85:
		return {"label":"fly",      "angle_range": angle_fly,     "ev_mul": ev_mul_fly,     "travel_px": travel_fly}
	else:
		var t = clamp((q - 0.70) / 0.30, 0.0, 1.0)
		var blast_p = lerp(0.08, 0.22, t)
		var use_blast = randf() < blast_p
		if use_blast:
			return {"label":"blast", "angle_range": angle_blast, "ev_mul": ev_mul_blast, "travel_px": travel_blast}
		else:
			return {"label":"fly",   "angle_range": angle_fly,   "ev_mul": ev_mul_fly,   "travel_px": travel_fly}

func _play_swing_pose() -> void:
	if sprite:
		sprite.rotation = deg_to_rad(-18)

func _reset_pose() -> void:
	if sprite:
		if abs(sprite.rotation) > 0.001:
			sprite.rotation = lerp(sprite.rotation, 0.0, 0.35)
		else:
			sprite.rotation = 0.0
