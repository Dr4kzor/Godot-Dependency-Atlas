@tool
extends ConfirmationDialog

## Asks once for permission to delete files.
##
## The checkbox exists so that enabling deletion cannot happen by reflex:
## Accept stays disabled until it is ticked, which forces the warning to be
## read rather than dismissed.

signal permission_granted

const DeletionManager = preload("res://addons/orphan_finder/graph3d/deletion_manager.gd")

var _acknowledge: CheckBox


func _init() -> void:
	title = "Enable deleting files"
	ok_button_text = "Enable deletion"
	cancel_button_text = "Cancel"
	min_size = Vector2i(560, 460)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var box := VBoxContainer.new()
	margin.add_child(box)

	var body := RichTextLabel.new()
	body.bbcode_enabled = false
	body.fit_content = true
	body.custom_minimum_size = Vector2(520, 330)
	body.text = DeletionManager.permission_text()
	box.add_child(body)

	box.add_child(HSeparator.new())

	_acknowledge = CheckBox.new()
	_acknowledge.text = "I have a backup or committed my work, and I understand files go to the trash"
	_acknowledge.toggled.connect(_on_acknowledged)
	box.add_child(_acknowledge)

	confirmed.connect(_on_confirmed)


func _on_acknowledged(pressed: bool) -> void:
	get_ok_button().disabled = not pressed


func _on_confirmed() -> void:
	if _acknowledge.button_pressed:
		permission_granted.emit()


## Reset each time it opens, so a previous tick never carries over.
func prepare() -> void:
	_acknowledge.button_pressed = false
	get_ok_button().disabled = true
