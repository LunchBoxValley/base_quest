# res://ui/UmpireHUD.gd
extends Control
class_name UmpireHUD

@export var home_plate_path: NodePath
@export var batter_path: NodePath
@export var field_path: NodePath                 # NEW: wire to Field (FieldJudge)
@export var call_flash_time: float = 0.7
@export var anchor_corner: int = Control.PRESET_TOP_LEFT
@export var anchor_offset: Vector2 = Vector2(4, 4)

@onready var timer: Timer         = $CallTimer
@onready var lbl_call: Label      = $"VBox/Call"
@onready var lbl_balls: Label     = $"VBox/Row/Balls"
@onready var lbl_strikes: Label   = $"VBox/Row/Strikes"
@onready var lbl_outs: Label      = $"VBox/Row/Outs"

var balls := 0
var strikes := 0
var outs := 0

func _ready() -> void:
	set_anchors_preset(anchor_corner)
	position = anchor_offset
	mouse_filter = MOUSE_FILTER_IGNORE

	if not (lbl_call and lbl_balls and lbl_strikes and lbl_outs and timer):
		push_error("[UmpireHUD] Missing child nodes. Check scene paths.")
		return

	lbl_call.text = ""
	_wire_plate()
	_wire_batter()
	_wire_field()   # NEW
	_render()

	if not timer.timeout.is_connected(_on_call_timer_timeout):
		timer.timeout.connect(_on_call_timer_timeout)

func _wire_plate() -> void:
	var plate := get_node_or_null(home_plate_path)
	if plate == null: return
	if not plate.called_strike.is_connected(_on_called_strike):
		plate.called_strike.connect(_on_called_strike)
	if not plate.called_ball.is_connected(_on_called_ball):
		plate.called_ball.connect(_on_called_ball)

func _wire_batter() -> void:
	var bat := get_node_or_null(batter_path)
	if bat == null: return
	if bat.has_signal("hit") and not bat.hit.is_connected(_on_batter_hit):
		bat.hit.connect(_on_batter_hit)

func _wire_field() -> void:
	var field := get_node_or_null(field_path)
	if field == null: return
	if field.has_signal("foul_ball") and not field.foul_ball.is_connected(_on_foul_ball):
		field.foul_ball.connect(_on_foul_ball)
	if field.has_signal("home_run") and not field.home_run.is_connected(_on_home_run):
		field.home_run.connect(_on_home_run)

func _on_batter_hit() -> void:
	_flash_call("HIT!")

func _on_foul_ball() -> void:
	# Foul = strike unless already 2
	if strikes < 2:
		strikes += 1
		_render()
	_flash_call("FOUL")

func _on_home_run() -> void:
	_flash_call("HOME RUN!")

func _on_called_strike() -> void:
	strikes += 1
	_flash_call("STRIKE")
	if strikes >= 3:
		strikes = 0
		balls = 0
		outs += 1
		_flash_call("STRIKEOUT")
	_render()

func _on_called_ball() -> void:
	balls += 1
	_flash_call("BALL")
	if balls >= 4:
		balls = 0
		strikes = 0
		_flash_call("WALK")
	_render()

func _flash_call(t: String) -> void:
	lbl_call.text = t
	timer.start(call_flash_time)

func _on_call_timer_timeout() -> void:
	lbl_call.text = ""

func _render() -> void:
	var old_b := lbl_balls.text
	var old_s := lbl_strikes.text
	var old_o := lbl_outs.text

	lbl_balls.text   = "B: %d" % balls
	lbl_strikes.text = "S: %d" % strikes
	lbl_outs.text    = "O: %d" % outs

	if lbl_balls.text != old_b: _pulse(lbl_balls)
	if lbl_strikes.text != old_s: _pulse(lbl_strikes)
	if lbl_outs.text != old_o: _pulse(lbl_outs)

func _pulse(lbl: Label) -> void:
	lbl.scale = Vector2(1.08, 1.08)
	var tw := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "scale", Vector2.ONE, 0.12)
