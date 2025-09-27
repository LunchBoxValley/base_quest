# res://scenes/main/base.gd
extends Node2D
class_name BaseNode

signal force_out(runner_id: int)
signal runner_safe(runner_id: int)

@export var name_tag: String = "FIRST"           # "HOME" / "FIRST" / "SECOND" / "THIRD"
@export var radius_px: float = 8.0               # used for legacy proximity checks and nearest-ball lookup
@export var require_throw_for_out: bool = true   # if true: only a thrown ball “controls” the bag
@export var legacy_polling_enabled: bool = false # keep old behavior as a fallback (OFF by default)

# --- State timestamps (seconds) ---
var _ball_control_time: float = -1.0             # when ball was controlled on bag
var _ball_control_kind: String = ""              # "throw" / "carry" / "unknown"
var _runner_arrival_time: Dictionary = {}        # { runner_instance_id: time }

func _ready() -> void:
	set_physics_process(legacy_polling_enabled)

func _physics_process(_dt: float) -> void:
	if not legacy_polling_enabled:
		return
	# Legacy: proximity-based detection (slow; event-based is preferred)
	_legacy_check_ball()
	_legacy_check_runners()

# =====================  EVENT API (preferred)  =====================

## Called by a Fielder that currently has the ball while overlapping this base's zone.
## Optionally pass the Ball (or a delivery kind) if you want to be explicit.
func ball_controlled_on_bag(ball: Node = null, delivery_kind: String = "") -> void:
	var kind := delivery_kind
	# Try to infer kind from the Ball if not provided
	if kind == "":
		if ball != null and is_instance_valid(ball) and ball.has_method("last_delivery"):
			kind = String(ball.last_delivery()).to_lower()
		else:
			# Fallback: look for the nearest Ball within radius and sample its last_delivery
			var b := _nearest_ball_within(radius_px)
			if b != null and b.has_method("last_delivery"):
				kind = String(b.last_delivery()).to_lower()
			else:
				kind = "unknown"

	# Respect rule: if require_throw_for_out, ignore non-throws
	if require_throw_for_out and kind != "throw":
		return

	# Stamp only the first control this play
	if _ball_control_time < 0.0:
		_ball_control_time = Time.get_ticks_msec() * 0.001
		_ball_control_kind = kind

## Called by the Runner when their foot hits this base.
## Returns true if the Runner is OUT (force), false if SAFE.
func runner_arrived(runner: Node) -> bool:
	if runner == null or not is_instance_valid(runner):
		return false
	var rid := int(runner.get_instance_id())
	var now := Time.get_ticks_msec() * 0.001
	if not _runner_arrival_time.has(rid):
		_runner_arrival_time[rid] = now

	var rt := float(_runner_arrival_time[rid])
	var bt := _ball_control_time

	var is_out := (bt >= 0.0 and bt <= rt)
	if is_out:
		force_out.emit(rid)
	else:
		runner_safe.emit(rid)
	return is_out

## Reset the base state for a new play (call from your GameManager at start of each live ball)
func new_play_reset() -> void:
	_ball_control_time = -1.0
	_ball_control_kind = ""
	_runner_arrival_time.clear()

# =====================  Helpers  =====================

func _nearest_ball_within(max_dist: float) -> Node:
	var best: Node = null
	var best_d := 1e9
	for n in get_tree().get_nodes_in_group("balls"):
		if n == null or not is_instance_valid(n):
			continue
		var d := (n as Node2D).global_position.distance_to(global_position)
		if d <= max_dist and d < best_d:
			best_d = d
			best = n
	return best

# =====================  Legacy (optional)  =====================

func _legacy_check_ball() -> void:
	var now := Time.get_ticks_msec() * 0.001
	for n in get_tree().get_nodes_in_group("balls"):
		var b := n as Node2D
		if b == null: 
			continue
		var d := b.global_position.distance_to(global_position)
		if d <= radius_px and _ball_control_time < 0.0:
			var kind := "unknown"
			if b.has_method("last_delivery"):
				kind = String(b.last_delivery()).to_lower()
			if not require_throw_for_out or kind == "throw":
				_ball_control_time = now
				_ball_control_kind = kind

func _legacy_check_runners() -> void:
	var now := Time.get_ticks_msec() * 0.001
	for n in get_tree().get_nodes_in_group("runners"):
		var r := n as Node2D
		if r == null:
			continue
		# Legacy proximity arrival; modern flow should call runner_arrived(r) directly.
		var d := r.global_position.distance_to(global_position)
		if d <= radius_px:
			var rid := int(r.get_instance_id())
			if not _runner_arrival_time.has(rid):
				_runner_arrival_time[rid] = now
				# Immediately judge on first arrival
				var rt := float(_runner_arrival_time[rid])
				var bt := _ball_control_time
				if bt >= 0.0 and bt <= rt:
					force_out.emit(rid)
				else:
					runner_safe.emit(rid)
