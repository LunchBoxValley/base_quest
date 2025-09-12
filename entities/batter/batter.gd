extends Node2D
class_name Batter

signal hit

@export var home_plate_path: NodePath
@export var swing_window: float = 0.12       # seconds the bat is “hot”
@export var sweet_spot_phase: float = 0.5    # 0..1 inside the window (0=start, 1=end)
@export var sweet_width: float = 0.30        # how wide around sweet_spot_phase counts as “good”
@export var hit_radius_px: float = 8.0
@export var contact_speed: float = 260.0     # base exit velocity
@export var timing_side_gain: float = 0.6    # early pulls left, late pushes right
@export var spray_random: float = 0.15       # extra horizontal spray on bad timing

# Simple “stat” for now; later swap for a real player struct
@export var power_stat: float = 1.0          # 0.7 (weak) .. 1.3 (slugger)

@export var bat_offset: Vector2 = Vector2(0, -2)

@onready var sprite: AnimatedSprite2D= $Sprite
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
	# Timing phase inside the swing window: 0=start, 1=end
	var phase = 1.0 - clamp(_swing_t / max(0.0001, swing_window), 0.0, 1.0)
	var offset = phase - sweet_spot_phase
	var norm = clamp(abs(offset) / max(0.0001, sweet_width), 0.0, 1.0)
	var timing_quality = 1.0 - norm  # 1 = perfect, 0 = terrible

	# Horizontal bias: early (offset<0) pulls left, late pushes right
	var side_bias = clamp(offset / max(0.0001, sweet_width), -1.0, 1.0) * timing_side_gain

	# Where on the plate we hit also nudges left/right
	var plate_x := (_plate.global_position.x if is_instance_valid(_plate) else global_position.x)
	var point_bias = clamp((hitpos.x - plate_x) / 12.0, -1.0, 1.0)

	# Add a bit of random spray if timing is bad
	var spray = randf_range(-spray_random, spray_random) * (1.0 - timing_quality)

	var dx = clamp(point_bias + side_bias + spray, -1.0, 1.0)
	var up = lerp(0.6, 1.0, timing_quality)  # bad timing = flatter, perfect = steeper up
	var dir := Vector2(dx * 0.6, -up).normalized()

	# Speed scales with timing + power stat
	var spd = contact_speed * lerp(0.7, 1.3, timing_quality) * clamp(power_stat, 0.5, 1.6)
	ball.deflect(dir, spd)

	# Let the ball stay around longer on great contact
	ball.max_travel = max(ball.max_travel, 260.0 + 120.0 * timing_quality * clamp(power_stat, 0.5, 1.6))

	# Juice: tiny camera kick
	var cam := get_tree().get_first_node_in_group("game_camera")
	if cam and cam.has_method("kick"):
		cam.kick(2.0, 0.12)

	hit.emit()

func _play_swing_pose() -> void:
	if sprite:
		sprite.rotation = deg_to_rad(-18)

func _reset_pose() -> void:
	if sprite:
		if abs(sprite.rotation) > 0.001:
			sprite.rotation = lerp(sprite.rotation, 0.0, 0.35)
		else:
			sprite.rotation = 0.0
