# res://scenes/main/pitcher.gd
extends Node2D
class_name Pitcher

# Scenes/paths
@export var ball_scene: PackedScene = preload("res://entities/ball/ball.tscn")
@export var home_plate_path: NodePath  # drag your HomePlate node here

# Tuning
@export var pitch_speed: float = 220.0
@export var aim_slots_per_side: int = 3           # -3..3 (7 slots total)
@export var strike_zone_half_width: float = 12.0  # if zone_size.x == 24, this is 12
@export var out_of_zone_extra: float = 3.0        # furthest slot sits just outside zone edge

# Visuals
@export var draw_aim_indicator: bool = true

@onready var hand: Marker2D = $Hand

var _aim_slot: int = 0        # -3..3, 0 is center
var _home_plate: Node2D

func _ready() -> void:
	add_to_group("pitcher")
	_home_plate = get_node_or_null(home_plate_path)
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if Input.is_action_just_pressed("aim_left"):
		_aim_slot = max(_aim_slot - 1, -aim_slots_per_side)
		queue_redraw()
	elif Input.is_action_just_pressed("aim_right"):
		_aim_slot = min(_aim_slot + 1, aim_slots_per_side)
		queue_redraw()
	elif Input.is_action_just_pressed("pitch"):
		_do_pitch()

func _do_pitch() -> void:
	var scene: PackedScene = ball_scene if ball_scene != null else preload("res://entities/ball/ball.tscn")
	var b := scene.instantiate()

	# Spawn under Entities (Pitcher’s parent), keeps hierarchy tidy
	var container := get_parent()
	if container:
		container.add_child(b)
	else:
		get_tree().current_scene.add_child(b)

	# Clamp travel so the ball reaches the plate but not far beyond
	if is_instance_valid(_home_plate) and b is Ball:
		var travel := (_home_plate.global_position.y - hand.global_position.y) + 4.0
		if travel > 40.0: # safety floor so extremely close layouts still move
			b.max_travel = travel

	# Compute direction toward the targeted X on the plate
	var dir := _compute_pitch_direction()
	b.pitch_from(hand.global_position, dir, pitch_speed)

	# Camera follow live ball, then return to pitcher when ball is done
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("follow_target"):
		cam.call("follow_target", b)
		if b.has_signal("out_of_play"):
			b.out_of_play.connect(func():
				if is_instance_valid(cam) and cam.has_method("follow_default"):
					cam.call("follow_default")
			)

func _compute_pitch_direction() -> Vector2:
	# Aim to a discrete X on the plate so left/right never wander far
	if is_instance_valid(_home_plate):
		var max_offset := strike_zone_half_width + out_of_zone_extra
		var step := max_offset / float(aim_slots_per_side)   # e.g., 3 slots → thirds
		var offset_x := _aim_slot * step

		var target := _home_plate.global_position
		target.x += offset_x
		# Ensure the target is below the hand so the ball travels downward
		if target.y <= hand.global_position.y:
			target.y = hand.global_position.y + 120.0

		return (target - hand.global_position).normalized()
	else:
		# Fallback if plate not set: small angular nudge
		var base := Vector2.DOWN
		var strength := 0.25
		var offset := Vector2(float(_aim_slot) * strength, 0.0)
		return (base + offset).normalized()

func _draw() -> void:
	# Placeholder pitcher body
	draw_rect(Rect2(Vector2(-4, -8), Vector2(8, 16)), Color(0.9, 0.9, 1.0), true)

	# Aim indicator arrow from the hand
	if draw_aim_indicator and is_instance_valid(hand):
		var dir := _compute_pitch_direction()
		var start := hand.position
		var end := start + dir * 12.0
		draw_line(start, end, Color(1, 1, 0), 1.0, true)
		var side := dir.rotated(0.9) * 4.0
		var side2 := dir.rotated(-0.9) * 4.0
		draw_line(end, end - side, Color(1, 1, 0), 1.0, true)
		draw_line(end, end - side2, Color(1, 1, 0), 1.0, true)
