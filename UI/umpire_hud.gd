extends Control
class_name UmpireHUD

@export var balls_label_path: NodePath
@export var strikes_label_path: NodePath
@export var outs_label_path: NodePath
@export var flash_label_path: NodePath

@export var max_balls: int = 4
@export var max_strikes: int = 3

# Flash colors
@export var color_ball: Color   = Color(1.0, 0.95, 0.2, 1.0)  # yellow
@export var color_strike: Color = Color(1.0, 0.15, 0.15, 1.0)  # red
@export var color_hit: Color    = Color(0.2, 1.0, 0.4, 1.0)    # green
@export var color_foul: Color   = Color(0.35, 0.6, 1.0, 1.0)   # BLUE (requested)
@export var color_out: Color    = Color(1.0, 0.3, 0.3, 1.0)

# Generic flash timings
@export var flash_in: float = 0.06
@export var flash_hold: float = 0.16
@export var flash_out: float = 0.12
@export var flash_scale: float = 1.15

# Home run strobe settings
@export var hr_color_a: Color = Color(1.0, 1.0, 1.0, 1.0)   # white
@export var hr_color_b: Color = Color(1.0, 0.2, 0.2, 1.0)   # red
@export var hr_strobe_count: int = 6                        # number of color swaps
@export var hr_strobe_interval: float = 0.06                # time per color tween
@export var hr_scale: float = 1.20                          # a little larger on HR
@export var hr_fade_out: float = 0.20

var balls: int = 0
var strikes: int = 0
var outs: int = 0

var _lbl_b: Label
var _lbl_s: Label
var _lbl_o: Label
var _lbl_flash: Label
var _flash_tw: Tween

func _ready() -> void:
	add_to_group("umpire_hud")
	_lbl_b = _fetch_label(balls_label_path, ["Balls", "Ball", "B"])
	_lbl_s = _fetch_label(strikes_label_path, ["Strikes", "Strike", "S"])
	_lbl_o = _fetch_label(outs_label_path, ["Outs", "Out", "O"])
	_lbl_flash = _fetch_label(flash_label_path, ["Flash", "Call", "UmpFlash"])
	if _lbl_flash:
		_lbl_flash.visible = false
		_lbl_flash.modulate.a = 0.0
	_refresh()

# ---------- Public API ----------
func reset_counts(keep_outs: bool = true) -> void:
	balls = 0
	strikes = 0
	if not keep_outs:
		outs = 0
	_refresh()

func call_ball() -> void:
	balls += 1
	_flash_text("BALL", color_ball)
	if balls >= max_balls:
		# Walk: clear pitch count
		balls = 0
		strikes = 0
	_refresh()

func call_strike() -> void:
	strikes += 1
	if strikes >= max_strikes:
		outs += 1
		_flash_text("STRIKEOUT", color_strike)
		balls = 0
		strikes = 0
	else:
		_flash_text("STRIKE", color_strike)
	_refresh()

func call_foul() -> void:
	# Foul adds a strike only up to 2
	if strikes < max_strikes - 1:
		strikes += 1
	_flash_text("FOUL", color_foul)  # BLUE
	_refresh()

func call_hit() -> void:
	# Fair hit: clear pitch count; outs unchanged
	balls = 0
	strikes = 0
	_flash_text("HIT!", color_hit)   # GREEN
	_refresh()

func call_out() -> void:
	outs += 1
	balls = 0
	strikes = 0
	_flash_text("OUT", color_out)
	_refresh()

# NEW: Home run call — strobing white/red
func call_home_run() -> void:
	# Treat like a hit for count purposes
	balls = 0
	strikes = 0
	_flash_home_run()
	_refresh()

# ---------- Internals ----------
func _refresh() -> void:
	if _lbl_b: _lbl_b.text = "B: %d" % balls
	if _lbl_s: _lbl_s.text = "S: %d" % strikes
	if _lbl_o: _lbl_o.text = "O: %d" % outs

func _flash_text(t: String, c: Color) -> void:
	if _lbl_flash == null:
		return
	if _flash_tw and _flash_tw.is_valid():
		_flash_tw.kill()
	_lbl_flash.text = t
	_lbl_flash.visible = true
	_lbl_flash.modulate = Color(c.r, c.g, c.b, 0.0)
	_lbl_flash.scale = Vector2.ONE
	_flash_tw = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_flash_tw.tween_property(_lbl_flash, "modulate:a", 1.0, flash_in)
	_flash_tw.tween_property(_lbl_flash, "scale", Vector2.ONE * flash_scale, flash_in)
	_flash_tw.tween_interval(flash_hold)
	_flash_tw.tween_property(_lbl_flash, "modulate:a", 0.0, flash_out)
	_flash_tw.tween_property(_lbl_flash, "scale", Vector2.ONE, flash_out)
	_flash_tw.tween_callback(Callable(self, "_hide_flash"))

func _flash_home_run() -> void:
	if _lbl_flash == null:
		return
	if _flash_tw and _flash_tw.is_valid():
		_flash_tw.kill()

	_lbl_flash.text = "HOME RUN!"
	_lbl_flash.visible = true
	_lbl_flash.scale = Vector2.ONE
	_lbl_flash.modulate = hr_color_a  # start at white, fully visible

	var tw := create_tween().set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	_flash_tw = tw

	# pop in a bit
	tw.tween_property(_lbl_flash, "scale", Vector2.ONE * hr_scale, flash_in)

	# strobe white <-> red for hr_strobe_count cycles
	var cycles = max(1, hr_strobe_count)
	for i in range(cycles):
		tw.tween_property(_lbl_flash, "modulate", hr_color_b, hr_strobe_interval)
		tw.tween_property(_lbl_flash, "modulate", hr_color_a, hr_strobe_interval)

	# fade out and settle scale
	tw.tween_property(_lbl_flash, "modulate:a", 0.0, hr_fade_out)
	tw.tween_property(_lbl_flash, "scale", Vector2.ONE, hr_fade_out)
	tw.tween_callback(Callable(self, "_hide_flash"))

func _hide_flash() -> void:
	if _lbl_flash:
		_lbl_flash.visible = false

func _fetch_label(path: NodePath, name_hints: Array) -> Label:
	var n: Node = get_node_or_null(path)
	if n and n is Label:
		return n as Label
	var found := _find_label_by_names(self, name_hints)
	if found:
		return found
	# Last resort: create a Label so we never null-ref (kept invisible until used)
	var lb := Label.new()
	lb.text = ""
	lb.visible = false
	add_child(lb)
	return lb

func _find_label_by_names(root: Node, hints: Array) -> Label:
	if root is Label:
		var name_u := root.name.to_upper()
		for h in hints:
			if name_u.find(String(h).to_upper()) >= 0:
				return root
	for c in root.get_children():
		var got := _find_label_by_names(c, hints)
		if got:
			return got
	return null
