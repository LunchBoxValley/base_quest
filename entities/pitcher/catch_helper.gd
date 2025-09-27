extends Node2D
class_name PitcherCatch

signal pitcher_gloved_ball(ball: Node2D)

@export_group("Scene Paths")
@export var glove_path: NodePath

@export_group("Catching")
@export var catch_radius_px: float = 30.0
@export var graze_extra_px: float = 6.0
@export var min_catch_speed: float = 0.0
@export var max_catch_speed_to_pitcher: float = 210.0
@export var require_approaching: bool = true
@export var approach_dot_threshold: float = 0.20
@export var catch_cooldown_sec: float = 0.12

@export_group("After Catch FX")
@export var end_play_on_catch: bool = true
@export var despawn_delay_sec: float = 0.45
@export var puff_on_catch: bool = true
@export var puff_lifetime_sec: float = 0.45

@export_group("Flow")
@export var require_play_active: bool = false

@export_group("Debug")
@export var debug_prints: bool = false
@export var debug_draw: bool = false

var _glove: Node2D = null
var _cooldown_until: float = 0.0
var _held_ball: Node2D = null  # latched so we don't re-catch

func _ready() -> void:
	if glove_path != NodePath():
		_glove = get_node_or_null(glove_path) as Node2D
	if _glove == null:
		_glove = get_node_or_null("Glove") as Node2D
	if _glove == null:
		_glove = self
	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	# If we're holding a ball, pin it to the glove and don't scan.
	if is_instance_valid(_held_ball):
		_held_ball.global_position = _glove.global_position
		return

	if require_play_active and not GameManager.play_active:
		return

	var now := Time.get_ticks_msec() * 0.001
	if now < _cooldown_until:
		return

	var ball := _find_throw_candidate()
	if ball == null:
		if debug_prints: print("[PitcherCatch] no candidate")
		return

	var gpos := _glove.global_position
	var bpos := ball.global_position
	var to_glove := gpos - bpos
	var dist := to_glove.length()
	var max_dist := catch_radius_px + graze_extra_px
	if dist > max_dist:
		if debug_prints: print("[PitcherCatch] too far (", dist, " > ", max_dist, ")")
		return

	var vel := _get_ball_velocity(ball)
	var speed := vel.length()

	# Reject anything too hot for a gentle toss-back.
	if speed > max_catch_speed_to_pitcher:
		if debug_prints: print("[PitcherCatch] too fast for glove: ", speed)
		return

	if require_approaching and speed > 0.001 and dist > 4.0:
		var dir_ball := vel / speed
		var dir_to_glove = to_glove / max(0.001, dist)
		var dot := dir_ball.dot(dir_to_glove)
		if dot < approach_dot_threshold:
			if debug_prints: print("[PitcherCatch] not approaching (dot=", dot, ")")
			return

	_glove_ball(ball, gpos)
	_cooldown_until = now + catch_cooldown_sec

func _glove_ball(ball: Node2D, glove_pos: Vector2) -> void:
	if debug_prints:
		print("[PitcherCatch] GLOVE at ", glove_pos)

	# Stop & snap; no global process freeze—use latch instead.
	_set_ball_velocity(ball, Vector2.ZERO)
	if ball.has_method("clear_spin"):
		ball.call("clear_spin")
	ball.global_position = glove_pos

	# Mark as caught with override that trumps last_delivery().
	ball.set_meta("delivery", "caught")
	ball.set_meta("delivery_override", "caught")
	ball.set_meta("caught_by", "pitcher")

	# Ensure it won't be considered again.
	if ball.is_in_group("balls"):
		ball.remove_from_group("balls")

	# Latch as held so we keep it pinned and never re-catch.
	_held_ball = ball

	# Soft smoke puff to mask despawn (optional)
	if puff_on_catch:
		_spawn_puff(glove_pos, puff_lifetime_sec)

	emit_signal("pitcher_gloved_ball", ball)

	# Schedule a fast despawn (hide within <1s)
	_despawn_after_delay()

	if end_play_on_catch:
		if debug_prints: print("[PitcherCatch] end_play()")
		GameManager.end_play()

func _despawn_after_delay() -> void:
	var t := get_tree().create_timer(max(0.05, despawn_delay_sec), true, true)
	await t.timeout
	if is_instance_valid(_held_ball):
		_held_ball.visible = false
		# If you pool balls, replace with pool return.
		_held_ball.queue_free()
	_held_ball = null

# ----------------- Candidate selection (strict throws only) -----------------
func _find_throw_candidate() -> Node2D:
	var best: Node2D = null
	var best_score := -1e9
	var gpos := (_glove.global_position if _glove else global_position)

	for n in get_tree().get_nodes_in_group("balls"):
		var b := n as Node2D
		if b == null:
			continue
		if b == _held_ball:
			continue  # never reconsider what we hold

		var delivery := _delivery_of(b).to_lower()
		# Only consider true throws (prevents catching own pitch/hits).
		if delivery != "throw":
			if debug_prints: print("[PitcherCatch] skip: delivery=", delivery)
			continue
		# Optional: ignore throws made by pitcher himself.
		if b.has_meta("thrown_by") and String(b.get_meta("thrown_by")).to_lower() == "pitcher":
			if debug_prints: print("[PitcherCatch] skip: thrown_by=pitcher")
			continue

		var dist := gpos.distance_to(b.global_position)
		var vel := _get_ball_velocity(b)
		var speed := vel.length()
		var toward := 0.0
		if speed > 0.001 and dist > 0.001:
			var dir_ball := vel / speed
			var dir_to_glove := (gpos - b.global_position) / dist
			toward = dir_ball.dot(dir_to_glove)

		var score := -dist + toward * 15.0
		if score > best_score:
			best_score = score
			best = b

	return best

# ----------------- Helpers -----------------
func _delivery_of(b: Node2D) -> String:
	# Prefer explicit meta override if present.
	if b.has_meta("delivery_override"):
		return String(b.get_meta("delivery_override"))
	if b.has_meta("delivery"):
		return String(b.get_meta("delivery"))
	if b.has_method("last_delivery"):
		return String(b.call("last_delivery"))
	return "unknown"

func _get_ball_velocity(b: Node2D) -> Vector2:
	if b.has_method("get_velocity"):
		var v = b.call("get_velocity")
		if typeof(v) == TYPE_VECTOR2:
			return v
	var v1 = b.get("velocity")
	if typeof(v1) == TYPE_VECTOR2:
		return v1
	var v2 = b.get("linear_velocity")
	if typeof(v2) == TYPE_VECTOR2:
		return v2
	return Vector2.ZERO

func _set_ball_velocity(b: Node2D, v: Vector2) -> void:
	if b.has_method("set_velocity"):
		b.call("set_velocity", v)
	elif b.has_method("set_linear_velocity"):
		b.call("set_linear_velocity", v)
	elif b.has_method("set"):
		if typeof(b.get("velocity")) == TYPE_VECTOR2:
			b.set("velocity", v)
		elif typeof(b.get("linear_velocity")) == TYPE_VECTOR2:
			b.set("linear_velocity", v)

# --- tiny smoke puff (soft, gray, upward drift) ---
func _spawn_puff(at: Vector2, life: float) -> void:
	var p := CPUParticles2D.new()
	p.one_shot = true
	p.local_coords = true
	p.lifetime = max(0.2, life)
	p.amount = 8
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINT
	p.position = to_local(at)

	# Soft motion (no damping property used)
	p.initial_velocity_min = 10.0
	p.initial_velocity_max = 16.0
	p.direction = Vector2(0, -1)   # slight upward bias
	p.spread = 20.0                # tight fan, not explosive
	p.gravity = Vector2(0, -18)    # gentle rise

	# Fade via color ramp
	var grad := Gradient.new()
	grad.add_point(0.0, Color(0.92, 0.92, 0.92, 0.50))
	grad.add_point(0.6, Color(0.88, 0.88, 0.88, 0.25))
	grad.add_point(1.0, Color(0.85, 0.85, 0.85, 0.0))
	p.color_ramp = grad

	add_child(p)
	p.emitting = true

	# Auto-remove puff after it finishes
	var t := get_tree().create_timer(p.lifetime + 0.1, true, true)
	await t.timeout
	if is_instance_valid(p):
		p.queue_free()

# ----------------- Debug draw -----------------
func _draw() -> void:
	if not debug_draw:
		return
	var g := (_glove if _glove != null else self)
	draw_circle(to_local(g.global_position), catch_radius_px, Color(0.2, 0.9, 0.3, 0.15))
	draw_circle(to_local(g.global_position), catch_radius_px + graze_extra_px, Color(0.2, 0.9, 0.3, 0.08))
	draw_circle(to_local(g.global_position), 2.0, Color(0.2, 0.9, 0.3, 0.8))
