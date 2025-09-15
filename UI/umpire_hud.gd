extends Control
class_name UmpireHUD

@export_group("Label Paths (optional)")
@export var balls_label_path: NodePath
@export var strikes_label_path: NodePath
@export var outs_label_path: NodePath
@export var flash_label_path: NodePath

@export_group("Flash Durations")
@export var flash_time: float = 0.30
@export var hr_strobe_time: float = 0.70
@export var hr_strobe_cycles: int = 5

const COL_STRIKE := Color(1.0, 0.15, 0.15)
const COL_HIT    := Color(0.20, 1.0, 0.20)
const COL_BALL   := Color(1.0, 0.95, 0.25)
const COL_FOUL   := Color(0.30, 0.55, 1.0)
const COL_WHITE  := Color(1,1,1)

var balls: int = 0
var strikes: int = 0
var outs: int = 0

@onready var _balls_label  : Label = _find_label(balls_label_path, "BallsLabel")
@onready var _strikes_label: Label = _find_label(strikes_label_path, "StrikesLabel")
@onready var _outs_label   : Label = _find_label(outs_label_path, "OutsLabel")
@onready var _flash_label  : Label = _find_label(flash_label_path, "FlashLabel")

var _flash_tween: Tween

func _ready() -> void:
	add_to_group("umpire_hud")
	visible = true

	GameManager.count_changed.connect(_on_count_changed)
	GameManager.outs_changed.connect(_on_outs_changed)
	GameManager.message.connect(_on_message)

	_update_count_labels()
	if _flash_label:
		_flash_label.visible = false
		_flash_label.modulate = COL_WHITE
		_flash_label.scale = Vector2.ONE

# Optional bridge
func set_count(b: int, s: int, o: int) -> void:
	balls = b; strikes = s; outs = o
	_update_count_labels()

func announce(kind: String) -> void:
	_on_message(kind)

func flash_message(text: String, color: Color, seconds: float = 0.4) -> void:
	_do_flash(text, color, seconds, false)

# Signals
func _on_count_changed(b: int, s: int) -> void:
	balls = b; strikes = s
	_update_count_labels()

func _on_outs_changed(o: int) -> void:
	outs = o
	_update_count_labels()

func _on_message(kind: String) -> void:
	var k := kind.to_upper()
	if k == "BALL":
		_do_flash("BALL", COL_BALL, flash_time, false)
	elif k == "STRIKE" or k == "K":
		_do_flash("STRIKE", COL_STRIKE, flash_time, false)
	elif k == "HIT":
		_do_flash("HIT!", COL_HIT, flash_time, false)
	elif k == "FOUL":
		_do_flash("FOUL", COL_FOUL, flash_time, false)
	elif k == "HR" or k == "HOME_RUN":
		_do_flash("HOME RUN!", COL_WHITE, hr_strobe_time, true)
	elif k == "OUT":
		_do_flash("OUT", COL_STRIKE, flash_time, false)
	elif k == "WALK":
		_do_flash("WALK", COL_BALL, flash_time, false)
	elif k == "GAME_OVER":
		_do_flash("GAME OVER", COL_WHITE, 1.2, false)

# Internals
func _find_label(path: NodePath, fallback_name: String) -> Label:
	var node: Node = null
	if path != NodePath():
		node = get_node_or_null(path)
	if node == null:
		node = find_child(fallback_name, true, false)
	return node as Label

func _update_count_labels() -> void:
	if _balls_label:   _balls_label.text   = "B: %d" % balls
	if _strikes_label: _strikes_label.text = "S: %d" % strikes
	if _outs_label:    _outs_label.text    = "O: %d" % outs

func _kill_flash() -> void:
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null

func _do_flash(text: String, color: Color, duration: float, strobe_hr: bool) -> void:
	if _flash_label == null:
		return
	_kill_flash()
	_flash_label.text = text
	_flash_label.visible = true
	_flash_label.modulate = color
	_flash_label.scale = Vector2.ONE * 0.85
	_flash_label.modulate.a = 1.0

	_flash_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

	if strobe_hr:
		var per = max(0.06, duration / float(max(hr_strobe_cycles, 1)))
		for i in hr_strobe_cycles:
			_flash_tween.tween_property(_flash_label, "modulate", Color(1,0.2,0.2), per * 0.5)
			_flash_tween.tween_property(_flash_label, "modulate", COL_WHITE, per * 0.5)
		_flash_tween.tween_property(_flash_label, "scale", Vector2.ONE, 0.12)
		_flash_tween.tween_property(_flash_label, "modulate:a", 0.0, 0.22)
	else:
		_flash_tween.tween_property(_flash_label, "scale", Vector2.ONE, 0.10)
		_flash_tween.tween_property(_flash_label, "modulate:a", 0.0, max(0.1, duration * 0.75))
	_flash_tween.tween_callback(Callable(self, "_hide_flash"))

func _hide_flash() -> void:
	if _flash_label:
		_flash_label.visible = false
