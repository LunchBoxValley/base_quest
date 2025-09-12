# res://ui/UmpireHUD.gd
extends Control
class_name UmpireHUD

@export var home_plate_path: NodePath      # drag your HomePlate node here
@export var call_flash_time: float = 0.7   # seconds the big call stays visible
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
	# Anchor to top-left and ignore mouse so gameplay input passes through.
	set_anchors_preset(anchor_corner)
	position = anchor_offset
	mouse_filter = MOUSE_FILTER_IGNORE

	# Guard against missing nodes (prevents the "null instance .text" error)
	if not (lbl_call and lbl_balls and lbl_strikes and lbl_outs and timer):
		push_error("[UmpireHUD] One or more child nodes not found. Check your scene paths/names.")
		return

	lbl_call.text = ""
	_wire_plate()
	_render()

	if not timer.timeout.is_connected(_on_call_timer_timeout):
		timer.timeout.connect(_on_call_timer_timeout)

func _wire_plate() -> void:
	var plate := get_node_or_null(home_plate_path)
	if plate == null:
		push_warning("[UmpireHUD] home_plate_path is not set or not found.")
		return

	# Godot 4 style: connect via signal objects, avoid duplicate connects.
	if not plate.called_strike.is_connected(_on_called_strike):
		plate.called_strike.connect(_on_called_strike)
	if not plate.called_ball.is_connected(_on_called_ball):
		plate.called_ball.connect(_on_called_ball)

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
	if lbl_call:
		lbl_call.text = t
	timer.start(call_flash_time)

func _on_call_timer_timeout() -> void:
	if lbl_call:
		lbl_call.text = ""

func _render() -> void:
	if lbl_balls:   lbl_balls.text   = "B: %d" % balls
	if lbl_strikes: lbl_strikes.text = "S: %d" % strikes
	if lbl_outs:    lbl_outs.text    = "O: %d" % outs
