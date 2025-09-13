extends Control
class_name PitchMeter

signal finished(power: float, accuracy: float)
signal phase_locked(phase: int, value: float)

@export var show_ui: bool = false
@export var anchor_corner: int = Control.PRESET_TOP_LEFT
@export var anchor_offset: Vector2 = Vector2(4, 4)
@export var speed: float = 2.0
@export var bar_width: float = 48.0

@onready var fg: ColorRect = $BarFG

var _t: float = 0.0
var _phase: int = 0       # 0 = power, 1 = accuracy, 2 = done
var running: bool = false

var power: float = 0.5
var accuracy: float = 0.5

func _ready() -> void:
	set_anchors_preset(anchor_corner)
	position = anchor_offset
	mouse_filter = MOUSE_FILTER_IGNORE
	visible = show_ui
	add_to_group("pitch_meter")
	set_process(true)

func start() -> void:
	running = true
	_phase = 0
	_t = 0.0
	if show_ui:
		visible = true
		if fg: fg.size.x = 0.0

func stop() -> void:
	running = false
	if show_ui:
		visible = false

func lock() -> void:
	if not running:
		return
	if _phase == 0:
		power = _current_value()
		phase_locked.emit(0, power)
		_phase = 1
		_t = 0.0
	elif _phase == 1:
		accuracy = _current_value()
		phase_locked.emit(1, accuracy)
		_phase = 2
		running = false
		if show_ui:
			visible = false
		finished.emit(power, accuracy)

func _process(delta: float) -> void:
	if not running:
		return
	_t += delta * speed
	var v := _current_value()
	if show_ui and fg:
		fg.size.x = int(bar_width * v)

func _current_value() -> float:
	var r := fposmod(_t, 2.0)
	return r if r <= 1.0 else (2.0 - r)

func current_value() -> float:
	if running:
		return _current_value()
	return power if _phase >= 1 else 0.0

func current_phase() -> int:
	return _phase
