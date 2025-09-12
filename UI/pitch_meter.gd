extends Control
class_name PitchMeter

signal finished(power: float, accuracy: float)

@export var speed: float = 2.0  # cycles per second
@onready var fg: ColorRect = $BarFG

var _t := 0.0
var _phase := 0        # 0 = power, 1 = accuracy, 2 = done
var running := false

var power := 0.5
var accuracy := 0.5

func _ready() -> void:
	set_process(true)
	visible = false
	add_to_group("pitch_meter")  # so Pitcher can find it

func start() -> void:
	visible = true
	running = true
	_phase = 0
	_t = 0.0

func stop() -> void:
	running = false
	visible = false

func lock() -> void:
	if not running:
		return
	if _phase == 0:
		power = _current_value()
		_phase = 1
		_t = 0.0
	elif _phase == 1:
		accuracy = _current_value()
		_phase = 2
		running = false
		visible = false
		emit_signal("finished", power, accuracy)

func _process(delta: float) -> void:
	if not running:
		return
	_t += delta * speed
	var v := _current_value()
	# assume BarFG width target is 48 px; adjust if you used a different size
	fg.size.x = int(48.0 * v)

func _current_value() -> float:
	# ping-pong 0..1..0 sweep
	var r := fposmod(_t, 2.0)
	return r if r <= 1.0 else 2.0 - r
