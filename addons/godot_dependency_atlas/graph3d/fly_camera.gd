extends Camera3D

## Emitted only from wheel input, so the viewer can report the new value
## without also firing when the layout auto-scales speed on rebuild.
signal speed_changed(value: float)
## Lets the viewer drop UI focus while flying: a focused Tree treats W/A/S/D
## as incremental-search keystrokes and jumps its selection around.
signal capture_changed(captured: bool)

## Free-fly camera: click to capture the mouse, WASD to move, Q/E for down/up,
## Shift to boost, Esc to release the mouse.
##
## Reads keys via Input.is_key_pressed rather than named actions so the viewer
## works in any project without needing Input Map entries added first.

@export var move_speed := 30.0
@export var boost_multiplier := 5.0
@export var mouse_sensitivity := 0.0022
@export var pitch_limit := 1.45  # just under 90 degrees, avoids gimbal flip

## Wheel adjusts speed multiplicatively, so it scales sensibly whether you're
## inspecting one node or crossing the whole graph.
const SPEED_STEP := 1.25
const SPEED_MIN := 2.0
const SPEED_MAX := 2000.0

## --- focus animation -------------------------------------------------------
## Flying to a file happens in two phases: turn to face it, then travel to it.
## Both durations and the easing curve are tunable here.
enum Easing { LINEAR, SINE_IN_OUT, QUAD_IN_OUT, CUBIC_IN_OUT, EXPO_OUT }

@export var focus_rotate_seconds := 0.45
@export var focus_travel_seconds := 0.95
@export var focus_easing: Easing = Easing.SINE_IN_OUT
## How quickly the camera keeps re-aiming at the target while travelling.
## Higher = the target stays more rigidly centred.
@export var focus_tracking_sharpness := 8.0

var _focus_active := false
var _focus_phase := 0        # 0 = rotating in place, 1 = travelling
var _focus_t := 0.0
var _focus_target_point := Vector3.ZERO
var _focus_end_position := Vector3.ZERO
var _focus_start_position := Vector3.ZERO
var _focus_start_yaw := 0.0
var _focus_start_pitch := 0.0
var _focus_target_yaw := 0.0
var _focus_target_pitch := 0.0

var _captured := false
var _yaw := 0.0
var _pitch := 0.0


func is_captured() -> bool:
	return _captured


## Smoothly turns to face `target_point`, then travels to a standoff position
## near it. Interrupted by any manual input, so it never fights the user.
func focus_on(target_point: Vector3, standoff: Vector3) -> void:
	_focus_target_point = target_point
	_focus_end_position = target_point + standoff
	_focus_start_position = position
	_focus_start_yaw = _yaw
	_focus_start_pitch = _pitch
	var aim := _angles_towards(target_point, position)
	_focus_target_yaw = aim.x
	_focus_target_pitch = aim.y
	_focus_phase = 0
	_focus_t = 0.0
	_focus_active = true


func cancel_focus() -> void:
	_focus_active = false


## Turns to look at a point without moving. Used when something starts
## happening off-screen and the view needs to face it, but relocating the
## camera would throw away the vantage point the user picked.
func face_towards(point: Vector3) -> void:
	var aim := _angles_towards(point, position)
	_focus_target_point = point
	_focus_end_position = position
	_focus_start_position = position
	_focus_start_yaw = _yaw
	_focus_start_pitch = _pitch
	_focus_target_yaw = aim.x
	_focus_target_pitch = aim.y
	_focus_phase = 0
	_focus_t = 0.0
	_focus_active = true


## Yaw/pitch that would make the camera look at `point` from `from`.
func _angles_towards(point: Vector3, from: Vector3) -> Vector2:
	var dir := point - from
	if dir.length_squared() < 0.0001:
		return Vector2(_yaw, _pitch)
	dir = dir.normalized()
	return Vector2(atan2(-dir.x, -dir.z), asin(clampf(dir.y, -1.0, 1.0)))


func _ease(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	match focus_easing:
		Easing.SINE_IN_OUT:
			return -(cos(PI * x) - 1.0) / 2.0
		Easing.QUAD_IN_OUT:
			return 2.0 * x * x if x < 0.5 else 1.0 - pow(-2.0 * x + 2.0, 2.0) / 2.0
		Easing.CUBIC_IN_OUT:
			return 4.0 * x * x * x if x < 0.5 else 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0
		Easing.EXPO_OUT:
			return 1.0 if x >= 1.0 else 1.0 - pow(2.0, -10.0 * x)
	return x


func _update_focus(delta: float) -> void:
	if _focus_phase == 0:
		var rotate_duration := maxf(focus_rotate_seconds, 0.001)
		_focus_t += delta / rotate_duration
		var e := _ease(_focus_t)
		# lerp_angle takes the shortest way round, so a turn never spins the
		# long way to reach an angle just across the wrap point.
		_yaw = lerp_angle(_focus_start_yaw, _focus_target_yaw, e)
		_pitch = lerpf(_focus_start_pitch, _focus_target_pitch, e)
		_apply_rotation()
		if _focus_t >= 1.0:
			_focus_phase = 1
			_focus_t = 0.0
		return

	var travel_duration := maxf(focus_travel_seconds, 0.001)
	_focus_t += delta / travel_duration
	position = _focus_start_position.lerp(_focus_end_position, _ease(_focus_t))
	# Keep re-aiming during the approach: the bearing to the target shifts as
	# we close on it, and without this the target drifts off-centre.
	var aim := _angles_towards(_focus_target_point, position)
	var tracking := clampf(delta * focus_tracking_sharpness, 0.0, 1.0)
	_yaw = lerp_angle(_yaw, aim.x, tracking)
	_pitch = lerpf(_pitch, aim.y, tracking)
	_apply_rotation()
	if _focus_t >= 1.0:
		_focus_active = false


## Called by the viewer once the graph exists, to frame it sensibly.
func look_at_from(from: Vector3, target: Vector3) -> void:
	_focus_active = false
	position = from
	var dir := (target - from).normalized()
	_yaw = atan2(-dir.x, -dir.z)
	_pitch = asin(clampf(dir.y, -1.0, 1.0))
	_apply_rotation()


func _apply_rotation() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)


func set_captured(value: bool) -> void:
	if _captured == value:
		return
	_captured = value
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE
	capture_changed.emit(value)


func _any_move_key_pressed() -> bool:
	for key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E]:
		if Input.is_key_pressed(key):
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		set_captured(false)
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			move_speed = clampf(move_speed * SPEED_STEP, SPEED_MIN, SPEED_MAX)
			speed_changed.emit(move_speed)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = clampf(move_speed / SPEED_STEP, SPEED_MIN, SPEED_MAX)
			speed_changed.emit(move_speed)
			return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# First click only grabs the mouse; once captured, clicks are free to
		# be used for picking by the viewer.
		if not _captured:
			set_captured(true)
			get_viewport().set_input_as_handled()
		return

	if _captured and event is InputEventMouseMotion:
		_focus_active = false
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -pitch_limit, pitch_limit)
		_apply_rotation()


func _process(delta: float) -> void:
	if _focus_active:
		if _any_move_key_pressed():
			_focus_active = false   # manual input always wins
		else:
			_update_focus(delta)
			return

	if not _captured:
		return

	var dir := Vector3.ZERO
	var basis_now := global_transform.basis
	if Input.is_key_pressed(KEY_W):
		dir -= basis_now.z
	if Input.is_key_pressed(KEY_S):
		dir += basis_now.z
	if Input.is_key_pressed(KEY_A):
		dir -= basis_now.x
	if Input.is_key_pressed(KEY_D):
		dir += basis_now.x
	if Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		dir -= Vector3.UP

	if dir == Vector3.ZERO:
		return

	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= boost_multiplier
	position += dir.normalized() * speed * delta
