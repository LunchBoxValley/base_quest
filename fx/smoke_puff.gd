extends CPUParticles2D

# If <= 0, we’ll auto-use the node’s built-in `lifetime`
@export var auto_free_delay: float = -1.0

func _ready() -> void:
	one_shot = true
	emitting = true
	var t := auto_free_delay
	if t <= 0.0:
		t = lifetime + 0.1  # tiny cushion to ensure all particles finish
	await get_tree().create_timer(t).timeout
	queue_free()
