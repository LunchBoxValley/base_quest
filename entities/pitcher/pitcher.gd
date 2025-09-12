# res://scenes/main/pitcher.gd
extends Node2D
class_name Pitcher

# Scenes/paths
@export var ball_scene: PackedScene = preload("res://entities/ball/ball.tscn")
@export var home_plate_path: NodePath                      # drag your HomePlate node here
@export var pitch_meter_path: NodePath                     # optional: drag your PitchMeter here (else we find group "pitch_meter")

# Tuning
@export var pitch_speed: float = 220.0
@export var aim_slots_per_side: int = 4                    # -4..+4 (9 slots total)
@export var strike_zone_half_width: float = 12.0           # if zone_size.x == 24, this is 12
@export var out_of_zone_extra: float = 2.0                 # furthest slot sits just outside zone edge

# Visuals
@export var draw_aim_indicator: bool = true

@onready var hand: Marker2D = $Hand

var _aim_slot: int = 0               # -aim_slots_per_side .. +aim_slots_per_side
var _home_plate: Node2D

# Meter state
var _meter_active := false

func _ready() -> void:
	add_to_group("pitcher")
	_home_plate = get_node_or_null(home_plate_path)
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	# Aim taps
	if Input.is_action_just_pressed("aim_left"):
		_aim_slot = max(_aim_slot - 1, -aim_slots_per_side)
		queue_redraw()
		return
	if Input.is_action_just_pressed("aim_right"):
		_aim_slot = min(_aim_slot + 1, aim_slots_per_side)
		queue_redraw()
		return

	# Pitch flow (with optional meter)
	if Input.is_action_just_pressed("pitch"):
		var meter := _get_meter()
		if meter:
			# 1st press starts; 2nd locks power; 3rd locks accuracy → emits finished(power, accuracy)
			if not _meter_active:
				_meter_active = true
				if not meter.is_connected("finished", Callable(self, "_on_meter_finished")):
					meter.finished.connect(_on_meter_finished)
				if meter.has_method("start"):
					meter.start()
			else:
				if meter.has_method("lock"):
					meter.lock()
		else:
			# No meter present → immediate throw
			_do_pitch(1.0, 1.0)

func _on_meter_finished(power: float, accuracy: float) -> void:
	_meter_active = false
	_do_pitch(power, accuracy)

func _get_meter() -> Node:
	var m := get_node_or_null(pitch_meter_path)
	if m == null:
		m = get_tree().get_first_node_in_group("pitch_meter")
	return m

func _do_pitch(power: float, accuracy: float) -> void:
	# Instantiate ball
	var scene: PackedScene = ball_scene if ball_scene != null else preload("res://entities/ball/ball.tscn")
	var b := scene.instantiate()

	# Spawn under Entities (Pitcher's parent) to keep hierarchy tidy
	var container := get_parent()
	if container:
		container.add_child(b)
	else:
		get_tree().current_scene.add_child(b)

	# Clamp travel so the ball reaches the plate but not far beyond
	if is_instance_valid(_home_plate) and b is Ball:
		var travel := (_home_plate.global_position.y - hand.global_position.y) + 4.0
		b.max_travel = max(travel, 40.0)  # safety floor

	# Register with the plate so it can judge STRIKE/BALL once
	if is_instance_valid(_home_plate) and _home_plate.has_method("register_ball"):
		_home_plate.register_ball(b)

	# Direction with accuracy-based wobble (small)
	var dir := _compute_pitch_direction_with_accuracy(accuracy)

	# Scale speed by power (arcade-friendly range ≈ 0.7x..1.3x)
	var speed_mult = clamp(0.7 + 0.6 * clamp(power, 0.0, 1.0), 0.1, 2.0)
	b.pitch_from(hand.global_position, dir, pitch_speed * speed_mult)

	# Camera follow live ball, then return to pitcher when ball is done
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("follow_target"):
		cam.call("follow_target", b)
		if b.has_signal("out_of_play"):
			b.out_of_play.connect(func():
				if is_instance_valid(cam) and cam.has_method("follow_default"):
					cam.call("follow_default")
			)

func _compute_pitch_direction_with_accuracy(accuracy: float) -> Vector2:
	if is_instance_valid(_home_plate):
		var max_offset := strike_zone_half_width + out_of_zone_extra
		var step := max_offset / float(aim_slots_per_side)
		var offset_x := _aim_slot * step

		# Tighter wobble than before (0.4 instead of 0.6)
		var wobble_amp = step * 0.4 * (1.0 - clamp(accuracy, 0.0, 1.0))
		offset_x += (randf() * 2.0 - 1.0) * wobble_amp

		var target := _home_plate.global_position
		target.x += offset_x
		if target.y <= hand.global_position.y:
			target.y = hand.global_position.y + 120.0
		return (target - hand.global_position).normalized()
	else:
		# Fallback if plate not set: small angular nudge with wobble
		var base := Vector2.DOWN
		var offset := Vector2(float(_aim_slot) * 0.18, 0.0)
		var wobble := Vector2((randf() * 2.0 - 1.0) * 0.08 * (1.0 - clamp(accuracy, 0.0, 1.0)), 0.0)
		return (base + offset + wobble).normalized()

func _draw() -> void:
	# Sprite2D child is the body; we only draw the aim arrow preview (no wobble)
	if draw_aim_indicator and is_instance_valid(hand):
		var dir := _compute_pitch_direction_with_accuracy(1.0)
		var start := hand.position
		var end := start + dir * 12.0
		draw_line(start, end, Color(1, 1, 0), 1.0, false)
		var side := dir.rotated(0.9) * 4.0
		var side2 := dir.rotated(-0.9) * 4.0
		draw_line(end, end - side, Color(1, 1, 0), 1.0, false)
		draw_line(end, end - side2, Color(1, 1, 0), 1.0, false)
