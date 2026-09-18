@tool
extends EditorPlugin

var dock : EditorDock
const CMD_RUNNER = preload("CmdRunner.tscn")

var debugger_handler : EditorDebuggerPlugin

func _enter_tree() -> void:
	var cmd_runner := CMD_RUNNER.instantiate()
	dock = EditorDock.new()
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BR
	dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	dock.add_child(cmd_runner)
	add_dock(dock)
	
	debugger_handler = CmdRunnerEditorDebuggerHandler.get_singleton()
	add_debugger_plugin(debugger_handler)

func _exit_tree() -> void:
	if dock:
		remove_dock(dock)
		dock.queue_free()
		dock = null
	
	if debugger_handler:
		remove_debugger_plugin(debugger_handler)
		debugger_handler = null
