# res://entities/ball.gd
extends Node2D
class_name Ball

signal out_of_play

@export var speed: float = 220.0
@export var max_travel: float = 200.0

@export_group("Spin")
@export var spin_fps: float = 18.0          # fallback rotation rate if no AnimatedSprite2D
@export var anim_speed_scale: float = 1.0    # multiplier for AnimatedSprite2D speed

var _velocity := Vector2.ZERO
var _active := false
var _start_pos := Vector2.ZERO

@onready var anim: AnimatedSprite2D = $Anim         # optional child
@onready var sprite: Sprite2D = $Sprite             # optional fallback
var _spin_t := 0.0
var _spin_active := false

func _ready() -> void:
	visible = false
	add_to_group("balls")

func pitch_from(start_global: Vector2, direction: Vector2 = Vector2.DOWN, custom_speed: float = -1.0) -> void:
	global_position = start_global
	_start_pos = start_global
	_velocity = direction.normalized() * (speed if custom_speed <= 0.0 else custom_speed)
	_active = true
	visible = true
	_start_spin()

func deflect(direction: Vector2, new_speed: float) -> void:
	_velocity = direction.normalized() * new_speed
	_active = true
	_start_pos = global_position
	max_travel = max(max_travel, 260.0)
	_start_spin()

func _start_spin() -> void:
	# Prefer AnimatedSprite2D if present and it has frames
	if anim and anim.sprite_frames:
		var frames := anim.sprite_frames
		var name := "spin"
		# In Godot 4, has_animation() lives on SpriteFrames
		if frames.has_animation(name):
			anim.animation = name
		else:
			var names := frames.get_animation_names()
			if names.size() > 0:
				anim.animation = names[0]
			else:
				# No animations at all → fallback to manual rotation
				_spin_t = 0.0
				_spin_active = true
				return
		anim.speed_scale = anim_speed_scale
		anim.play()
		_spin_active = false
	else:
		# No AnimatedSprite2D → rotate a plain Sprite2D as a tiny “spin” effect
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
		sprite.rotation = float(idx) * 0.5 * PI  # 0°, 90°, 180°, 270°

func _physics_process(delta: float) -> void:
	if not _active:
		return
	global_position += _velocity * delta

	if global_position.distance_to(_start_pos) >= max_travel:
		_active = false
		_stop_spin()
		out_of_play.emit()
		queue_free()
