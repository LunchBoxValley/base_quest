extends Node
# NOTE: Do NOT declare `class_name` here; the autoload name provides the global.

# ---- Config ----
@export var innings_per_game: int = 5
@export var cpu_defense_first: bool = true  # CPU pitches first if true

# ---- State ----
var inning: int = 1            # 1..innings_per_game
var half: int = 0              # 0 = top (CPU defense if cpu_defense_first), 1 = bottom
var balls: int = 0
var strikes: int = 0
var outs: int = 0
var game_over: bool = false
var play_active: bool = false  # true during live ball; false between plays

# ---- Signals ----
signal count_changed(balls: int, strikes: int)
signal outs_changed(outs: int)
signal half_inning_started(inning: int, half: int) # emitted after counts reset
signal play_state_changed(active: bool)            # true=start, false=end
signal message(kind: String)                       # "BALL", "STRIKE", "FOUL", "HIT", "HR", "WALK", "OUT", etc.
signal game_over_signal

func _ready() -> void:
	reset_game()

# ---------------- Public API ----------------

func reset_game() -> void:
	inning = 1
	half = 0
	balls = 0
	strikes = 0
	outs = 0
	game_over = false
	play_active = false
	count_changed.emit(balls, strikes)
	outs_changed.emit(outs)
	half_inning_started.emit(inning, half)

func start_play() -> void:
	if game_over: return
	if not play_active:
		play_active = true
		play_state_changed.emit(true)

func end_play() -> void:
	# Called when the ball is dead (foul, HR, out, or ball in play resolved)
	if play_active:
		play_active = false
		play_state_changed.emit(false)

func call_ball() -> void:
	if game_over: return
	start_play() # a live pitch happened
	balls += 1
	message.emit("BALL")
	if balls >= 4:
		message.emit("WALK")
		_reset_count()
	end_play()
	count_changed.emit(balls, strikes)

func call_strike() -> void:
	if game_over: return
	start_play()
	strikes += 1
	message.emit("STRIKE")
	if strikes >= 3:
		_register_out("K")
	end_play()
	count_changed.emit(balls, strikes)

func call_foul() -> void:
	if game_over: return
	start_play()
	# Foul is a strike unless already two strikes
	if strikes < 2:
		strikes += 1
		count_changed.emit(balls, strikes)
	message.emit("FOUL")
	end_play()

func call_hit(is_hr: bool=false) -> void:
	if game_over: return
	start_play()
	if is_hr:
		message.emit("HR")
	else:
		message.emit("HIT")
	# FieldJudge or the ball logic should call end_play() when resolved.

func register_out(reason: String="OUT") -> void:
	if game_over: return
	_register_out(reason)
	end_play()

# ---------------- Internals ----------------

func _register_out(reason: String) -> void:
	outs += 1
	message.emit(reason)
	_reset_count()
	outs_changed.emit(outs)
	if outs >= 3:
		_swap_sides()

func _swap_sides() -> void:
	outs = 0
	half = (half + 1) % 2
	if half == 0:
		inning += 1
	if inning > innings_per_game:
		_end_game()
		return
	# new half
	count_changed.emit(balls, strikes) # already reset in _reset_count
	outs_changed.emit(outs)
	half_inning_started.emit(inning, half)

func _reset_count() -> void:
	balls = 0
	strikes = 0
	count_changed.emit(balls, strikes)

func _end_game() -> void:
	game_over = true
	play_active = false
	game_over_signal.emit()
	message.emit("GAME_OVER")
	play_state_changed.emit(false)
