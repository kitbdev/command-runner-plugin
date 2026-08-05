@tool
extends EditorPlugin

var dock : EditorDock
const CMD_RUNNER = preload("res://addons/commandrunner/CmdRunner.tscn")

func _enter_tree() -> void:
	var cmd_runner := CMD_RUNNER.instantiate()
	dock = EditorDock.new()
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BR
	dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	dock.add_child(cmd_runner)
	add_dock(dock)

func _exit_tree() -> void:
	if dock:
		remove_dock(dock)
		dock.queue_free()
		dock = null
