# res://systems/game_juice.gd
extends Node
class_name GameJuice

@export var hitstop_time_scale: float = 0.02     # ~98% freeze; tweak to taste
@export var overlay_layer_index: int = 100       # draw on top

var _overlay_layer: CanvasLayer
var _hitstop_serial: int = 0

func _ready() -> void:
	# A private CanvasLayer we can draw flashes onto
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = overlay_layer_index
	add_child(_overlay_layer)

# --- Micro-freeze (Hitstop) ---
func hitstop(duration_s: float = 0.06) -> void:
	# Freeze almost everything by shrinking time_scale.
	_hitstop_serial += 1
	var my_id := _hitstop_serial
	Engine.time_scale = max(0.0001, hitstop_time_scale)
	# Fire the restore even while frozen.
	var t := get_tree().create_timer(max(duration_s, 0.01), true, true, false)
	t.timeout.connect(func():
		# Only the most recent hitstop restores the time scale.
		if _hitstop_serial == my_id:
			Engine.time_scale = 1.0
	)

# --- Fullscreen overlay flash (white by default) ---
func flash_overlay(time_s: float = 0.08, alpha: float = 0.20, color: Color = Color.WHITE) -> void:
	var rect := ColorRect.new()
	rect.color = Color(color.r, color.g, color.b, alpha)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Fill the screen, robust to resolution changes
	rect.anchor_left = 0.0; rect.anchor_top = 0.0
	rect.anchor_right = 1.0; rect.anchor_bottom = 1.0
	rect.offset_left = 0.0; rect.offset_top = 0.0
	rect.offset_right = 0.0; rect.offset_bottom = 0.0
	_overlay_layer.add_child(rect)
	var tw := rect.create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(rect, "modulate:a", 0.0, time_s)
	tw.tween_callback(rect.queue_free)

# --- Quick scale “pop” on any CanvasItem (labels, sprites, etc.) ---
func pulse_scale(item: CanvasItem, amount: float = 1.12, time_s: float = 0.10) -> void:
	if item == null:
		return
	var start = item.scale
	item.scale = start * amount
	var tw := item.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(item, "scale", start, time_s)

# --- One-shot UI sound (drop any AudioStream in) ---
func play_one_shot(stream: AudioStream, pitch_scale: float = 1.0, volume_db: float = 0.0, bus: String = "UI") -> void:
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.pitch_scale = pitch_scale
	p.volume_db = volume_db
	p.bus = bus
	_overlay_layer.add_child(p)
	p.play()
	var dur := 0.2
	if stream.has_method("get_length"):
		dur = max(0.05, stream.get_length())
	var t := get_tree().create_timer(dur, true, true, false)
	t.timeout.connect(p.queue_free)
