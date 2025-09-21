extends Node2D
class_name Pitcher

signal pitched(ball: Node2D)

@export var input_enabled: bool = true
@export var hand_path: NodePath
@export var camera_path: NodePath
@export var ball_scene: PackedScene

@export var charge_fx_path: NodePath

@export_group("Pitch Tuning")
@export var min_power_speed: float = 160.0
@export var max_power_speed: float = 320.0
@export var max_charge_seconds: float = 3.0

@export_group("Aim Slots")
@export var aim_step_deg: float = 4.0
@export var aim_slots_left: int = 4
@export var aim_slots_right: int = 4
@export var base_aim_deg: float = 0.0

@export_group("Charge Zoom (centered)")
@export var charge_zoom_scale: float = 0.80 # 20% zoom-IN while charging
@export var zoom_in_time: float = 0.35      # slower ease-in
@export var zoom_out_time: float = 0.10     # snap-back on release

@export_group("Accuracy & Steer")
@export var steer_max_deg: float = 8.0
@export var inaccuracy_max_deg: float = 10.0

@export_group("Human Cooldown")
@export var human_cooldown_min: float = 3.0

@onready var _hand: Node2D = get_node_or_null(hand_path)
@onready var _cam: Node = get_node_or_null(camera_path)

var _fx: Node = null
var _charging := false
var _charge_time := 0.0
var _aim_index := 0
var _play_locked := false

var _human_cooldown_active := false
var _human_cd_timer: SceneTreeTimer = null

func _ready() -> void:
	# Ensure input action exists (ENTER/SPACE)
	if not InputMap.has_action("pitch"):
		InputMap.add_action("pitch")
	var ev_enter := InputEventKey.new()
	ev_enter.keycode = KEY_ENTER
	InputMap.action_add_event("pitch", ev_enter)
	var ev_space := InputEventKey.new()
	ev_space.keycode = KEY_SPACE
	InputMap.action_add_event("pitch", ev_space)

	_resolve_fx()
	set_physics_process(true)

	GameManager.play_state_changed.connect(_on_play_state_changed)
	_reset_state()

func _on_play_state_changed(active: bool) -> void:
	_play_locked = active

func _reset_state() -> void:
	_charging = false
	_charge_time = 0.0
	_fx_stop()

# ---------------- INPUT (human) ----------------
func _input(event: InputEvent) -> void:
	if not input_enabled:
		return

	if (event.is_action_pressed("pitch") or event.is_action_pressed("ui_accept")) and not _charging:
		if _can_pitch_now():
			_start_charge()
		return

	if _charging and (event.is_action_released("pitch") or event.is_action_released("ui_accept")):
		var level = clamp(_charge_time / max(0.001, max_charge_seconds), 0.0, 1.0)
		var steer := _current_lr_steer()
		_throw_with(level, steer)
		return

func _physics_process(delta: float) -> void:
	if _charging:
		_charge_time = clamp(_charge_time + delta, 0.0, max_charge_seconds)
		var level = clamp(_charge_time / max(0.001, max_charge_seconds), 0.0, 1.0)
		_fx_set_level(0, level)
	_update_aim_from_input()

func _can_pitch_now() -> bool:
	if _human_cooldown_active:
		return false
	if not _play_locked:
		return true
	for n in get_tree().get_nodes_in_group("balls"):
		return false
	return true

func _start_charge() -> void:
	_charging = true
	_charge_time = 0.0
	_aim_index = 0

	_fx_start()
	_fx_set_level(0, 0.0)

	# Smoothly center on pitcher while charging (no snap), then zoom 20% in.
	var focus: Node2D = self
	if is_instance_valid(_hand):
		focus = _hand
	if _cam and _cam.has_method("begin_charge_focus"):
		_cam.call("begin_charge_focus", focus, false) # false = lerp to center (no jerk)
	if _cam and _cam.has_method("zoom_to"):
		_cam.call("zoom_to", charge_zoom_scale, zoom_in_time)
	else:
		# Fallback: property tween
		var z := Vector2(1.0 / max(charge_zoom_scale, 0.0001), 1.0 / max(charge_zoom_scale, 0.0001))
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(_cam, "zoom", z, zoom_in_time)

func _throw_with(level: float, steer_lr: float) -> void:
	var power = clamp(level, 0.0, 1.0)
	var acc = power
	var speed = lerp(min_power_speed, max_power_speed, power)

	var aim_deg := base_aim_deg + float(_aim_index) * aim_step_deg
	var steer_deg = clamp(steer_lr, -1.0, 1.0) * steer_max_deg
	var miss_deg = randf_range(-1.0, 1.0) * (1.0 - acc) * inaccuracy_max_deg
	var final_deg = aim_deg + steer_deg + miss_deg

	var b := _spawn_ball()
	if b:
		var origin: Vector2 = global_position
		if is_instance_valid(_hand):
			origin = _hand.global_position
		var dir := Vector2(sin(deg_to_rad(final_deg)), 1.0).normalized()

		_safe_call_pitch_from(b, origin, dir, speed, acc, steer_lr)

		# Safety: guarantee end_of_play even if other systems miss it
		if b.has_signal("out_of_play"):
			b.connect("out_of_play", Callable(GameManager, "end_play"))

		b.add_to_group("balls")
		pitched.emit(b)

	_charging = false
	_fx_release(power)

	# Snap back to default framing distance; keep focusing pitcher until play starts.
	if _cam and _cam.has_method("zoom_to"):
		_cam.call("zoom_to", 1.0, zoom_out_time)
	else:
		var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(_cam, "zoom", Vector2.ONE, zoom_out_time)
	if _cam and _cam.has_method("end_charge_focus"):
		_cam.call("end_charge_focus", false) # keep pitcher framing (no snap)

	_start_human_cooldown()

# ---------------- SPAWN ----------------
func _spawn_ball() -> Node2D:
	if ball_scene == null:
		push_error("[Pitcher] Assign Ball.tscn to 'ball_scene'.")
		return null
	var b := ball_scene.instantiate() as Node2D
	var parent := get_tree().get_current_scene()
	if parent == null:
		parent = get_parent()
	parent.add_child(b)
	if is_instance_valid(_hand):
		b.global_position = _hand.global_position
	else:
		b.global_position = global_position
	return b

# ---------------- AIM (slot nudge) ----------------
func _update_aim_from_input() -> void:
	var left := Input.is_action_pressed("ui_left")
	var right := Input.is_action_pressed("ui_right")
	var max_left := -aim_slots_left
	var max_right := aim_slots_right
	if left and not right:
		_aim_index = clamp(_aim_index - 1, max_left, max_right)
	elif right and not left:
		_aim_index = clamp(_aim_index + 1, max_left, max_right)

func _current_lr_steer() -> float:
	var s := (Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"))
	return clamp(s, -1.0, 1.0) * 0.10

# ---------------- HUMAN COOLDOWN ----------------
func _start_human_cooldown() -> void:
	if not input_enabled:
		return
	_human_cooldown_active = true
	if _human_cd_timer != null:
		return
	_human_cd_timer = get_tree().create_timer(max(0.01, human_cooldown_min))
	_human_cd_timer.timeout.connect(func ():
		_human_cooldown_active = false
		_human_cd_timer = null
	)

# ---------------- FX resolve & control ----------------
func _resolve_fx() -> void:
	_fx = null
	if charge_fx_path != NodePath():
		_fx = get_node_or_null(charge_fx_path)
	if _fx == null and is_instance_valid(_hand):
		_fx = _hand.get_node_or_null("PitchCharge")
	if _fx == null and is_instance_valid(_hand):
		for c in _hand.get_children():
			if c is CPUParticles2D:
				_fx = c
				break
	if _fx == null:
		for c in get_children():
			if c is CPUParticles2D:
				_fx = c
				break

	# Give particles a tiny white texture if missing
	if _fx is CPUParticles2D:
		var p := _fx as CPUParticles2D
		if p.texture == null:
			var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
			img.fill(Color(1,1,1,1))
			p.texture = ImageTexture.create_from_image(img)

func _fx_start() -> void:
	if _fx == null:
		return
	if _fx.has_method("start_charge"):
		_fx.call("start_charge")
	elif _fx is CPUParticles2D:
		var p := _fx as CPUParticles2D
		p.visible = true
		p.one_shot = false
		p.lifetime = 0.30
		p.modulate = Color(1.0, 0.82, 0.15, 0.70)
		p.amount = 12
		p.spread = 180.0
		p.emitting = false
		p.emitting = true

func _fx_set_level(phase: int, level: float) -> void:
	if _fx == null:
		return
	if _fx.has_method("set_level"):
		_fx.call("set_level", level, phase)
	elif _fx is CPUParticles2D:
		var p := _fx as CPUParticles2D
		level = clamp(level, 0.0, 1.0)
		if phase == 0:
			p.modulate = Color(1.0, 0.82, 0.15, 0.70).lerp(Color(1,1,0,1), level)
			p.amount = int(lerp(12.0, 120.0, level))
			p.spread = 180.0

func _fx_release(power: float) -> void:
	if _fx == null:
		return
	if _fx.has_method("release_burst"):
		_fx.call("release_burst", clamp(power, 0.0, 1.0))
	elif _fx is CPUParticles2D:
		var p := _fx as CPUParticles2D
		p.one_shot = true
		p.lifetime = 0.16
		p.amount = 36
		p.emitting = false
		p.emitting = true
		await get_tree().create_timer(0.12, true, true).timeout
		_fx_stop()

func _fx_stop() -> void:
	if _fx is CPUParticles2D:
		var p := _fx as CPUParticles2D
		p.emitting = false
		p.visible = false

# ----------------- AI hooks (keep parity with human path) -----------------
func ai_begin_charge_zoom() -> void:
	var focus: Node2D = self
	if is_instance_valid(_hand):
		focus = _hand
	if _cam and _cam.has_method("begin_charge_focus"):
		_cam.call("begin_charge_focus", focus, false)
	if _cam and _cam.has_method("zoom_to"):
		_cam.call("zoom_to", charge_zoom_scale, zoom_in_time)

func ai_begin_charge_fx() -> void:
	_fx_start()

func ai_set_charge_level(phase: int, level: float) -> void:
	_fx_set_level(phase, level)

func ai_pitch(power: float, accuracy: float, target_deg: float, steer_lr: float) -> void:
	var p = clamp(power, 0.0, 1.0)
	var acc = clamp(accuracy, 0.0, 1.0)
	var aim_deg := target_deg
	var speed = lerp(min_power_speed, max_power_speed, p)
	var steer_deg = clamp(steer_lr, -1.0, 1.0) * steer_max_deg
	var miss_deg = randf_range(-1.0, 1.0) * (1.0 - acc) * inaccuracy_max_deg
	var final_deg = aim_deg + steer_deg + miss_deg

	var b := _spawn_ball()
	if b:
		var origin: Vector2 = global_position
		if is_instance_valid(_hand):
			origin = _hand.global_position
		var dir := Vector2(sin(deg_to_rad(final_deg)), 1.0).normalized()

		_safe_call_pitch_from(b, origin, dir, speed, acc, steer_lr)

		# Safety: same out_of_play → end_play wiring on AI path
		if b.has_signal("out_of_play"):
			b.connect("out_of_play", Callable(GameManager, "end_play"))

		b.add_to_group("balls")
		pitched.emit(b)

	_fx_release(p)

	if _cam and _cam.has_method("zoom_to"):
		_cam.call("zoom_to", 1.0, zoom_out_time)
	if _cam and _cam.has_method("end_charge_focus"):
		_cam.call("end_charge_focus", false)

# ----------------- helpers -----------------
func _safe_call_pitch_from(ball: Object, origin: Vector2, dir: Vector2, speed: float, acc: float, steer: float) -> void:
	var argc := _get_method_argc(ball, "pitch_from")
	if argc >= 5:
		ball.call("pitch_from", origin, dir, speed, acc, steer)
	elif argc == 4:
		ball.call("pitch_from", origin, dir, speed, acc)
	elif argc == 3:
		ball.call("pitch_from", origin, dir, speed)
	else:
		if ball.has_method("set_velocity"):
			ball.call("set_velocity", dir * speed)
		if ball.has_method("set_accuracy"):
			ball.call("set_accuracy", acc)
		if ball.has_method("set_pitch_steer"):
			ball.call("set_pitch_steer", steer)
		if ball is Node:
			(ball as Node).set_meta("pitch_accuracy", acc)
			(ball as Node).set_meta("pitch_steer", steer)

func _get_method_argc(obj: Object, name: String) -> int:
	var list := obj.get_method_list()
	for m in list:
		var mname = m.get("name")
		if typeof(mname) == TYPE_STRING and String(mname) == name:
			var args = m.get("args")
			if typeof(args) == TYPE_ARRAY:
				return (args as Array).size()
	# default fallback
	return 0
