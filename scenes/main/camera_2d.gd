extends Camera2D
class_name GameCamera

@export var enable_on_start: bool = true

# Default framing (usually the Pitcher)
@export_node_path var default_target_path: NodePath
@export var default_offset: Vector2 = Vector2(0, -60)

# Follow & return timings
@export var post_play_hold_time: float = 0.40
@export var return_to_pitch_time: float = 0.70

# Optional bounds/overscroll
@export var clamp_to_bounds: bool = false
@export var bounds_rect: Rect2 = Rect2(Vector2.ZERO, Vector2(640, 360))
@export var follow_overscroll_enabled: bool = true
@export var follow_overscroll_pad: Vector2 = Vector2(48, 32)

# Charge focus
@export var charge_focus_offset: Vector2 = Vector2(0, 30)

var _default_target: Node = null
var _follow_target: Node = null
var _follow_target_weak: WeakRef = null
var _return_timer: SceneTreeTimer = null
var _is_charge_focus: bool = false

func _ready() -> void:
	if enable_on_start:
		enabled = true
	add_to_group("game_camera", true)

	if default_target_path != NodePath():
		_default_target = get_node_or_null(default_target_path)
	_follow_default(true)

func _process(_delta: float) -> void:
	if clamp_to_bounds and not _is_charge_focus:
		var pos := global_position
		pos.x = clampf(pos.x, bounds_rect.position.x, bounds_rect.position.x + bounds_rect.size.x)
		pos.y = clampf(pos.y, bounds_rect.position.y, bounds_rect.position.y + bounds_rect.size.y)
		global_position = pos

func begin_charge_focus(focus: Node, snap: bool = true) -> void:
	_is_charge_focus = true
	_follow_target = null
	_follow_target_weak = null
	_cancel_return_timer()

	var target_pos := _node_screen_anchor(focus) + charge_focus_offset
	if snap:
		global_position = target_pos
	else:
		create_tween().tween_property(self, "global_position", target_pos, 0.12)

func end_charge_focus(snap: bool = false) -> void:
	_is_charge_focus = false
	_follow_default(snap)

func follow_default(snap: bool = false) -> void:
	_follow_default(snap)

func follow_target(target: Node, snap: bool = true) -> void:
	if target == null:
		return
	_is_charge_focus = false
	_cancel_return_timer()
	_disconnect_from_current_follow()

	_follow_target = target
	_follow_target_weak = weakref(target)

	# Prefer custom signal; fall back to tree_exited if not present.
	if target.has_signal("out_of_play"):
		target.connect("out_of_play", Callable(self, "_on_follow_target_out_of_play"))
	else:
		target.connect("tree_exited",   Callable(self, "_on_follow_target_tree_exited"))

	var dest := _node_screen_anchor(target)
	if snap:
		global_position = dest
	else:
		create_tween().tween_property(self, "global_position", dest, 0.10)

func kick(amp: float = 8.0, dur: float = 0.08) -> void:
	var orig := global_position
	var tw := create_tween()
	tw.tween_property(self, "global_position", orig + Vector2(amp, -amp), dur * 0.5)
	tw.tween_property(self, "global_position", orig, dur * 0.5)

func hr_pan_out_and_back() -> void:
	var base_zoom := zoom
	var tw := create_tween()
	tw.tween_property(self, "zoom", base_zoom * 1.08, 0.20)
	tw.tween_property(self, "zoom", base_zoom, 0.28)

func _physics_process(_delta: float) -> void:
	if _follow_target_weak != null:
		var tgt = _follow_target_weak.get_ref()
		if tgt != null:
			global_position = _node_screen_anchor(tgt)

func _on_follow_target_out_of_play() -> void:
	if GameManager and GameManager.has_method("end_play"):
		GameManager.end_play()  # optional redundancy
	_schedule_return_to_default()

func _on_follow_target_tree_exited() -> void:
	_schedule_return_to_default()

func _schedule_return_to_default() -> void:
	_disconnect_from_current_follow()
	_cancel_return_timer()
	_return_timer = get_tree().create_timer(post_play_hold_time, false)
	_return_timer.timeout.connect(Callable(self, "_do_return_to_default"))

func _do_return_to_default() -> void:
	_follow_default(false)

func _follow_default(snap: bool) -> void:
	_follow_target = null
	_follow_target_weak = null
	if _default_target == null and default_target_path != NodePath():
		_default_target = get_node_or_null(default_target_path)
	var dest := _node_screen_anchor(_default_target) + default_offset
	if snap:
		global_position = dest
	else:
		create_tween().tween_property(self, "global_position", dest, return_to_pitch_time)

func _node_screen_anchor(n: Node) -> Vector2:
	if n == null:
		return global_position
	if n is Node2D:
		return n.global_position
	if n.has_method("get_global_position"):
		return n.get_global_position()
	return global_position

func _disconnect_from_current_follow() -> void:
	if _follow_target == null:
		return
	if _follow_target.has_signal("out_of_play"):
		if _follow_target.is_connected("out_of_play", Callable(self, "_on_follow_target_out_of_play")):
			_follow_target.disconnect("out_of_play", Callable(self, "_on_follow_target_out_of_play"))
	if _follow_target.is_connected("tree_exited", Callable(self, "_on_follow_target_tree_exited")):
		_follow_target.disconnect("tree_exited", Callable(self, "_on_follow_target_tree_exited"))

func _cancel_return_timer() -> void:
	if _return_timer != null:
		_return_timer = null
	
