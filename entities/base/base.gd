# res://scenes/main/base.gd
extends Node2D
class_name BaseNode

signal force_out(runner_id: int)
signal runner_safe(runner_id: int)

@export var radius_px: float = 8.0               # touch radius for base
@export var require_throw_for_out: bool = true   # no carry-outs
@export var name_tag: String = "FIRST"           # "HOME"/"FIRST"/"SECOND"

var _ball_arrival_time := -1.0
var _runner_arrival_time := {}   # { runner_id: time }
var _runner_present := {}        # { runner_id: bool }

func _ready() -> void:
	set_physics_process(true)

func _physics_process(_dt: float) -> void:
	_check_ball()
	_check_runners()

func _check_ball() -> void:
	var balls := get_tree().get_nodes_in_group("balls")
	if balls.is_empty(): return
	var now := Time.get_ticks_msec() * 0.001
	for b in balls:
		if not (b is Ball): continue
		var d = b.global_position.distance_to(global_position)
		if d <= radius_px:
			# Only count if delivered by a THROW when rule requires it
			if not require_throw_for_out or (b.has_method("last_delivery") and b.last_delivery() == "throw"):
				if _ball_arrival_time < 0.0:
					_ball_arrival_time = now

func _check_runners() -> void:
	var runners := get_tree().get_nodes_in_group("runners")
	if runners.is_empty(): return
	var now := Time.get_ticks_msec() * 0.001
	for r in runners:
		if not r.has_method("id") or not r.has_method("is_targeting_base"): continue
		var rid = r.id()
		var d = r.global_position.distance_to(global_position)
		if d <= radius_px:
			if r.is_targeting_base(self) and not _runner_present.get(rid, false):
				_runner_present[rid] = true
				if _runner_arrival_time.get(rid, -1.0) < 0.0:
					_runner_arrival_time[rid] = now
				_decide_call_for(rid)
		else:
			_runner_present[rid] = false

func _decide_call_for(rid: int) -> void:
	var rt = _runner_arrival_time.get(rid, -1.0)
	if rt < 0.0: return
	var bt := _ball_arrival_time

	if bt >= 0.0 and bt <= rt:
		force_out.emit(rid)
	else:
		runner_safe.emit(rid)
