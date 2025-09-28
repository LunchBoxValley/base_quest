extends Node2D
class_name Runner

signal reached_base(base_idx: int)
signal forced_out(base_idx: int)
signal scored()

@export_group("Movement")
@export var speed: float = 80.0
@export var acceleration: float = 600.0
@export var snap_dist: float = 6.0

@export_group("Pathing & Rules")
# Path order should be: [Home, 1B, 2B, 3B, Home]
@export var path: Array[NodePath] = []
@export var is_forced: bool = true       # batter-runner usually forced

@export_group("FX")
@export var smoke_fx: PackedScene        # assign SmokePuff.tscn

var _idx := 0
var _vel := Vector2.ZERO
var _alive := true

func _ready() -> void:
	add_to_group("runners")
	set_physics_process(true)

func id() -> int:
	return int(get_instance_id())

func begin_at_path_index(i: int) -> void:
	_idx = clamp(i, 0, path.size() - 1)
	var n := _target_node()
	if n:
		global_position = n.global_position
		_puff(global_position) # spawn poof at home

func commit_to_next() -> void:
	if _idx < path.size() - 1:
		_idx += 1

func get_next_path_index() -> int:
	# Return the index of the *next* base we’re heading to
	if path.is_empty():
		return 0
	return min(_idx + 1, path.size() - 1)

func next_base_path() -> NodePath:
	if path.is_empty():
		return NodePath()
	return path[get_next_path_index()]

func _physics_process(delta: float) -> void:
	if not _alive:
		return

	# Retreat rule: if heading 1->2 and 2B already has the ball, turn back to 1B.
	# Path indices: 0=Home, 1=1B, 2=2B, 3=3B, 4=Home
	if _idx == 2:
		var base2 := _node_from_path_index(2)
		if base2 and base2.has_method("ball_present") and base2.ball_present():
			_idx = 1  # go back to first

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
	return _node_from_path_index(_idx)

func _node_from_path_index(i: int) -> Node2D:
	if i < 0 or i >= path.size():
		return null
	return get_node_or_null(path[i]) as Node2D

func _arrive_at_base(base_node: Node2D) -> void:
	# Ask the Base to judge. If out, it returns true.
	var is_out := false
	if base_node and base_node.has_method("runner_arrived"):
		is_out = base_node.runner_arrived(self)

	var base_idx := _idx

	if is_out:
		forced_out.emit(base_idx)
		_alive = false
		# Poof specifically on force-out at FIRST
		if base_idx == 1:
			_puff(global_position)
		queue_free()
		return

	reached_base.emit(base_idx)

	# Scored if this is the last node (Home at end of path)
	if _idx >= path.size() - 1:
		scored.emit()
		_alive = false
		_puff(global_position) # optional poof on scoring
		queue_free()
		return

	# Force advance if play rules say so
	if is_forced:
		commit_to_next()

# -------------------- FX --------------------
func _puff(pos: Vector2) -> void:
	if smoke_fx:
		var fx := smoke_fx.instantiate()
		var root := get_tree().get_current_scene()
		if root:
			root.add_child(fx)
			fx.global_position = pos
