@tool
class_name DeletionWarningOverlay
extends Control

## Reusable warning scene controller. Visual geometry and animation tracks are
## authored in deletion_warning_overlay.tscn; this script only exposes tuning
## and the armed/disarmed state to its two hosts.

@export_range(0.05, 8.0, 0.05) var light_rotation_speed := 1.0:
	set(value):
		light_rotation_speed = value
		_apply_tuning()

@export_range(0.25, 4.0, 0.05) var warning_scale := 1.0:
	set(value):
		warning_scale = value
		_apply_tuning()

@onready var _left_anchor: Control = $LeftWarning
@onready var _right_anchor: Control = $RightWarning
@onready var _pulse_animation: AnimationPlayer = $PulseAnimation
@onready var _light_animation: AnimationPlayer = $LightAnimation


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_tuning()
	set_warning_enabled(false)


func set_warning_enabled(enabled: bool) -> void:
	visible = enabled
	if not is_node_ready():
		return
	if enabled:
		_pulse_animation.play("pulse")
		_light_animation.play("rotate_light")
	else:
		_pulse_animation.stop()
		_light_animation.stop()


func _apply_tuning() -> void:
	if not is_node_ready():
		return
	var configured_scale := Vector2.ONE * warning_scale
	_left_anchor.scale = configured_scale
	_right_anchor.scale = configured_scale
	_light_animation.speed_scale = light_rotation_speed
