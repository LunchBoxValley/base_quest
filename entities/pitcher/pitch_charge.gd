extends CPUParticles2D
class_name PitchCharge

# --- Timings ---
@export var default_lifetime: float = 0.30
@export var burst_lifetime: float = 0.16
@export var dissolve_time: float = 0.12

# --- Counts / Sizes ---
@export var base_amount: int = 12
@export var max_amount: int = 120
@export var burst_amount: int = 36

@export var scale_min: float = 0.90
@export var scale_max: float = 2.10

# --- Colors ---
@export var color_min: Color = Color(1.0, 0.82, 0.15, 0.70) # amber
@export var color_full: Color = Color(1.0, 1.0, 0.0, 1.0)   # bright yellow (full)

# --- Motion encoding (maps to "info") ---
# POWER (phase 0): faster particles as charge rises.
@export var vel_min_base: float = 8.0
@export var vel_max_base: float = 16.0
@export var vel_min_full: float = 20.0
@export var vel_max_full: float = 36.0

# ACCURACY (phase 1): tighten spread as accuracy rises; narrow velocity band.
@export var spread_wide_deg: float = 180.0
@export var spread_tight_deg: float = 24.0

# FULL cue when phase==1 and level >= threshold
@export var full_threshold: float = 0.98
@export var full_pulse_scale: float = 1.12
@export var full_pulse_time: float = 0.10

var _level := 0.0           # 0..1 level for current phase
var _phase := 0             # 0=power, 1=accuracy, 2=done
var _tween: Tween
var _flag_full := false

func _ready() -> void:
	z_index = 50
	local_coords = true
	one_shot = false
	emitting = false
	lifetime = default_lifetime
	visible = false

	gravity = Vector2.ZERO
	spread = spread_wide_deg   # wide bloom by default

	if texture == null:
		push_warning("[PitchCharge] No Texture set (use a 2×2 or 4×4 white dot).")

func start_charge() -> void:
	_kill_tween()
	visible = true
	one_shot = false
	lifetime = default_lifetime
	amount = base_amount
	_level = 0.0
	_phase = 0
	_flag_full = false
	modulate = color_min
	scale = Vector2.ONE * scale_min

	# POWER defaults
	spread = spread_wide_deg
	initial_velocity_min = vel_min_base
	initial_velocity_max = vel_max_base

	emitting = false
	emitting = true

func set_level(v: float, phase: int = 0) -> void:
	# Called each frame by the Pitcher while the meter runs.
	_level = clamp(v, 0.0, 1.0)
	_phase = phase

	# Common: grow count and size
	amount = int(lerp(float(base_amount), float(max_amount), _level))
	scale  = Vector2.ONE * lerp(scale_min, scale_max, _level)

	if _phase == 0:
		# POWER: brighter + faster particles as power charges
		modulate = color_min.lerp(color_full, _level)
		initial_velocity_min = lerp(vel_min_base, vel_min_full, _level)
		initial_velocity_max = lerp(vel_max_base, vel_max_full, _level)
		spread = spread_wide_deg
		_flag_full = false  # reset (we only "full" on accuracy)
	elif _phase == 1:
		# ACCURACY: tighten spread, narrow velocity band, bright yellow at max
		modulate = color_min.lerp(color_full, _level)
		spread = lerp(spread_wide_deg, spread_tight_deg, _level)

		# Centered, narrowing band as accuracy rises
		var base_center := (vel_min_base + vel_max_base) * 0.5
		var full_center := (vel_min_full + vel_max_full) * 0.5
		var center = lerp(base_center, full_center, 0.6)
		var base_width := (vel_max_base - vel_min_base)
		var width = lerp(base_width, 2.0, _level)  # shrink randomness toward ~2 px/s
		initial_velocity_min = max(0.0, center - width * 0.5)
		initial_velocity_max = center + width * 0.5

		# FULL cue once when we cross threshold
		if not _flag_full and _level >= full_threshold:
			_flag_full = true
			_pulse_full()

func release_burst(power: float = 1.0) -> void:
	_kill_tween()
	one_shot = true
	lifetime = burst_lifetime
	amount = max(int(lerp(float(burst_amount), float(burst_amount) * 1.8, clamp(power, 0.0, 1.0))), 1)

	emitting = false  # retrigger one-shot
	emitting = true

	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "modulate:a", 0.0, dissolve_time)
	_tween.tween_callback(Callable(self, "_reset_after_burst"))

func _pulse_full() -> void:
	# Snap pulse to sell "max": quick up then settle.
	var start_s := scale
	scale = start_s * full_pulse_scale
	_kill_tween()
	_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", start_s, full_pulse_time)

func _reset_after_burst() -> void:
	emitting = false
	one_shot = false
	lifetime = default_lifetime
	modulate = color_min
	scale = Vector2.ONE * scale_min
	amount = base_amount
	spread = spread_wide_deg
	initial_velocity_min = vel_min_base
	initial_velocity_max = vel_max_base
	visible = false
	_flag_full = false

func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
		_tween = null
