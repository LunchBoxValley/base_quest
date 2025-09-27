# res://entities/runner/Runner.gd
extends Node2D
class_name Runner

signal reached_base(base_idx: int)
signal forced_out(base_idx: int)
signal scored()

@export var speed: float = 80.0
@export var acceleration: float = 600.0
@export var snap_dist: float = 6.0
@export var path: Array[NodePath] = []  # [Home, 1B, 2B, 3B, Home]
@export var is_forced: bool = true       # usually true for the batter-runner

var _idx := 0
var _vel := Vector2.ZERO
var _alive := true

func _ready() -> void:
	set_physics_process(true)

func begin_at_path_index(i: int) -> void:
	_idx = clamp(i, 0, path.size() - 1)
	var n := _target_node()
	if n:
		global_position = n.global_position

func commit_to_next() -> void:
	if _idx < path.size() - 1:
		_idx += 1

func _physics_process(delta: float) -> void:
	if not _alive:
		return
	var tgt := _target_node()
	if tgt == null:
		return
	var goal := tgt.global_position
	var to_vec := goal - global_position
	var dist := to_vec.length()
	var dir := Vector2.ZERO
	if dist > 0.001:
		dir = to_vec / dist
	_vel = _vel.move_toward(dir * speed, acceleration * delta)
	global_position += _vel * delta

	# Arrival by distance snap (you can also rely purely on BaseZone overlap)
	if dist <= max(snap_dist, speed * delta):
		_arrive_at_base(tgt)

func _target_node() -> Node2D:
	if _idx < 0 or _idx >= path.size():
		return null
	return get_node_or_null(path[_idx]) as Node2D

func _arrive_at_base(base_node: Node2D) -> void:
	# Ask the Base to judge. If out, it returns true.
	var is_out := false
	if base_node and base_node.has_method("runner_arrived"):
		is_out = base_node.runner_arrived(self)
	var base_idx := _idx

	if is_out:
		emit_signal("forced_out", base_idx)
		_alive = false
		queue_free()
		return

	emit_signal("reached_base", base_idx)

	# Scored if this is the last node (Home at end of path)
	if _idx >= path.size() - 1:
		emit_signal("scored")
		_alive = false
		queue_free()
		return

	# Force advance if play rules say so
	if is_forced:
		commit_to_next()
