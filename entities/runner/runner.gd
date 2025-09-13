extends Node2D
class_name Runner

@export var speed: float = 80.0
@export var path: Array[NodePath] = []  # e.g., [Home, First, Second, Home]

var _idx: int = 0
var _alive: bool = true
var _id: int = randi()

func _ready() -> void:
	add_to_group("runners")
	set_physics_process(true)

func id() -> int:
	return _id

func start_run() -> void:
	# Assume we spawn at Home (path[0]); target next base
	_idx = 1
	_alive = true

func is_targeting_base(b: Node) -> bool:
	if _idx >= path.size():
		return false
	var tgt := get_node_or_null(path[_idx])
	return tgt == b

func _physics_process(delta: float) -> void:
	if not _alive or _idx >= path.size():
		return
	var tgt_node := get_node_or_null(path[_idx])
	if tgt_node == null:
		return
	var to_vec: Vector2 = (tgt_node.global_position - global_position)
	var dist: float = to_vec.length()
	var step: float = speed * delta
	if dist <= max(1.0, step):
		global_position = tgt_node.global_position
		_idx += 1
		if _idx >= path.size():
			# reached Home — scored
			queue_free()
	else:
		global_position += to_vec.normalized() * step
