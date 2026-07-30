@tool
extends RefCounted

## Deletion of orphaned files, gated behind an explicit one-time permission.
##
## Everything here moves files to the OS trash rather than removing them.
## Orphan detection is a heuristic -- it cannot see runtime-built paths like
## load("res://levels/" + name) -- so an unrecoverable delete built on top of
## it is the wrong trade. Trash keeps a mistake fixable.
##
## Permission is granted once per session and reset by every rescan: the
## orphan list changes when the project does, and stale permission held
## against a fresh list is exactly where accidents happen.

signal permission_changed(granted: bool)
signal file_deleted(path: String, ok: bool, message: String)

const OFConfig = preload("res://addons/godot_dependency_atlas/graph3d/of_config.gd")
const REGISTRY_NAME := "deleted.log"

var _granted := false
var _scan_root := "res://"
var _deleted := {}      # path -> true, for as long as this scan's results stand


func configure(scan_root: String) -> void:
	_scan_root = scan_root


func is_granted() -> bool:
	return _granted


func grant() -> void:
	if _granted:
		return
	_granted = true
	permission_changed.emit(true)


## Called on every rescan. The previous answer was given about a list that no
## longer exists.
func revoke() -> void:
	_deleted.clear()
	if not _granted:
		return
	_granted = false
	permission_changed.emit(false)


func was_deleted(path: String) -> bool:
	return _deleted.has(path)


func deleted_count() -> int:
	return _deleted.size()


## The warning shown before permission is granted. Deliberately explicit
## about what the tool cannot know.
static func permission_text() -> String:
	return """Deleting files based on this scan

Before enabling deletion, please:

  • Commit your work to git, or take a backup.

Files are moved to your system trash, not erased, so a mistake can be
undone -- but only if you notice it.

What this tool cannot see:

  • Paths built at runtime, such as load("res://levels/" + level_name).
    A file loaded only that way looks exactly like an orphan.
  • References from compiled C# assemblies.
  • Anything reached through a plugin or tool script that builds paths
    dynamically.

A file listed as an orphan is a candidate for review, not a verdict.

Deletion stays enabled until the next scan, and every file removed is
recorded in dependency_atlas/deleted.log."""


## Moves a file to the OS trash and records it. Returns "" on success or an
## error message.
func delete_file(path: String, reason: String = "orphan") -> String:
	if not _granted:
		return "Deletion has not been enabled."
	if _deleted.has(path):
		return "Already deleted in this session."

	var absolute := ProjectSettings.globalize_path(path)
	if _scan_root != "res://":
		absolute = _scan_root.trim_suffix("/") + "/" + path.trim_prefix("res://")
	if not FileAccess.file_exists(absolute):
		return "File not found: %s" % absolute

	var size := 0
	var probe := FileAccess.open(absolute, FileAccess.READ)
	if probe != null:
		size = probe.get_length()
		probe.close()

	if OS.move_to_trash(absolute) != OK:
		var message := "Could not move to trash: %s" % path
		file_deleted.emit(path, false, message)
		return message

	# Sidecars are bookkeeping for the file itself, so they follow it rather
	# than being left behind as fresh orphans.
	for suffix_any in [".import", ".uid"]:
		# Explicitly typed: array literals yield Variant, so ":=" here has
		# nothing to infer from.
		var sidecar: String = absolute + String(suffix_any)
		if FileAccess.file_exists(sidecar):
			OS.move_to_trash(sidecar)

	_deleted[path] = true
	_record(path, size, reason)
	file_deleted.emit(path, true, "")
	return ""


## Appends to the audit log. Written as plain text and never read back by the
## tool: its purpose is for a human to reconstruct what happened.
func _record(path: String, size: int, reason: String) -> void:
	var problem := OFConfig.ensure_layout(_scan_root)
	if problem != "":
		push_warning("Dependency Atlas: " + problem)
		return

	var registry := OFConfig.data_dir(_scan_root) + "/" + REGISTRY_NAME
	var existed := FileAccess.file_exists(registry)
	var file := FileAccess.open(registry, FileAccess.READ_WRITE if existed else FileAccess.WRITE)
	if file == null:
		push_warning("Dependency Atlas: could not write %s" % registry)
		return
	if existed:
		file.seek_end()
	else:
		file.store_line("# Files moved to trash by Dependency Atlas.")
		file.store_line("# timestamp | path | bytes | why it was listed")
	file.store_line("%s | %s | %d | %s" % [
		Time.get_datetime_string_from_system(), path, size, reason
	])
	file.close()
