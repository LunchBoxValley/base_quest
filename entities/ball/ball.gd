extends Node2D
class_name Ball

signal out_of_play

@export var speed: float = 220.0
@export var max_travel: float = 200.0

@export_group("Spin")
@export var spin_fps: float = 18.0
@export var anim_speed_scale: float = 1.0

@export_group("Depth Scale — Pitch")
@export var near_y_pitch: float = 140.0
@export var far_y_pitch: float = 60.0
@export var scale_near_pitch: float = 1.00
@export var scale_far_pitch: float = 0.50

@export_group("Depth Scale — Hit (more dramatic)")
@export var near_y_hit: float = 140.0
@export var far_y_hit: float = 20.0
@export var scale_near_hit: float = 1.15
@export var scale_far_hit: float = 0.30
@export var hit_initial_shrink: float = 0.70      # immediate shrink multiplier at contact (<1 = smaller)
@export var hit_depth_boost_time: float = 0.22    # seconds to blend back to normal curve

@export_group("Depth Quantize")
@export var scale_quantize_step: float = 0.125    # 0 to disable

var _velocity := Vector2.ZERO
var _active := false
var _start_pos := Vector2.ZERO
var _is_hit := false

@onready var anim: AnimatedSprite2D = $Anim
@onready var sprite: Sprite2D = $Sprite
var _spin_t := 0.0
var _spin_active := false

var _hit_boost_t := 0.0

func _ready() -> void:
	visible = false
	add_to_group("balls")

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	global_position = start_global
	_start_pos = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	_is_hit = false
	_hit_boost_t = 0.0
	visible = true
	_start_spin()
	_update_depth_scale()

func deflect(direction: Vector2, new_speed: float) -> void:
	_velocity = direction.normalized() * new_speed
	_active = true
	_is_hit = true
	_start_pos = global_position
	_hit_boost_t = hit_depth_boost_time
	max_travel = max(max_travel, 260.0)
	_start_spin()
	_update_depth_scale()

func _start_spin() -> void:
	if anim and anim.sprite_frames:
		var frames := anim.sprite_frames
		var names := frames.get_animation_names()
		if names.size() > 0:
			anim.animation = ( "spin" if names.has("spin") else names[0] )
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

func _physics_process(delta: float) -> void:
	if not _active:
		return
	global_position += _velocity * delta
	if global_position.distance_to(_start_pos) >= max_travel:
		_active = false
		_stop_spin()
		out_of_play.emit()
		queue_free()

func _update_depth_scale() -> void:
	# Choose curve by state
	var near_y := near_y_hit if _is_hit else near_y_pitch
	var far_y :=  far_y_hit  if _is_hit else far_y_pitch
	var s_near := scale_near_hit if _is_hit else scale_near_pitch
	var s_far :=  scale_far_hit  if _is_hit else scale_far_pitch

	# Map y to 0..1 (0=far/top, 1=near/plate)
	var t = clamp(inverse_lerp(far_y, near_y, global_position.y), 0.0, 1.0)
	var s = lerp(s_far, s_near, t)

	# Extra early shrink right after contact (dramatic NES-style pop)
	if _is_hit and hit_depth_boost_time > 0.0:
		var k = clamp(_hit_boost_t / hit_depth_boost_time, 0.0, 1.0)  # 1..0
		var factor = lerp(1.0, hit_initial_shrink, k)                  # start smaller, relax to 1.0
		s *= factor

	if scale_quantize_step > 0.0:
		s = round(s / scale_quantize_step) * scale_quantize_step

	scale = Vector2.ONE * max(0.01, s)
