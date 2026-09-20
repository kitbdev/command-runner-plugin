@warning_ignore("missing_tool")
extends CommandRunnerBase
class_name CmdRunnerDebuggerRemoteExecuter

const message_prefix := "command_runner"

var selection: Object = null

func _enter_tree() -> void:
	EngineDebugger.register_message_capture(message_prefix, _message_capture)

func _exit_tree() -> void:
	EngineDebugger.unregister_message_capture(message_prefix)

func _ready() -> void:
	_custom_commands = CommandRunnerCustomCommands.new()
	_custom_commands.cmd_runner = self

func _message_capture(message: String, data: Array) -> bool:
	# this can freeze the editor if data is too long
	if verbose_mode: print(("CmdRunner debugger got message `%s` %s" % [message, data]).left(1000))
	if message == "run_cmd":
		if data.size() != 2 or data[0] is not String or data[1] is not bool:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true

		_update_inputs()
		var cmd_txt := data[0] as String
		var await_result := data[1] as bool
		var worked := _run_expression(cmd_txt)
		if worked and await_result:
			await _last_result
		send_message("cmd_finished", [OK, worked])
		return true
	if message == "set_selection":
		if data.size() != 1 or data[0] is not NodePath:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true
		var path := data[0] as NodePath
		selection = get_node(path)
		send_message("cmd_finished", [OK])
		return true
	#if message == "set_base_node":
		#if data.size() != 1 or data[0] is not NodePath:
			#send_message("cmd_finished", [ERR_INVALID_DATA])
			#return true
		#var path := data[0] as NodePath
		#_base_instance_node = get_node(path)
		#send_message("cmd_finished", [OK])
		#return true
	#if message == "get_inputs":
		#send_message("cmd_finished", [OK, _cmd_input_names])
		#return true
	if message == "get_completion":
		if data.size() != 1 or data[0] is not String:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true

		var cmd_txt := data[0] as String
		var result := get_completion_result_items(cmd_txt, true)
		send_message("cmd_finished", [OK, result])
		return true
	return false

func send_message(message: String, data: Array) -> void:
	EngineDebugger.send_message(message_prefix + ":" + message, data)

func output(output_text: String, is_escaped: bool = false) -> void:
	send_message("output", [output_text, is_escaped])

func outputerr(output_text: String) -> void:
	send_message("outputerr", [output_text])

func _update_inputs() -> void:
	_base_cmd_input_names = ["sel", "allvars", "cmd_runner", "cmds"]
	_cmd_input_names = _base_cmd_input_names.duplicate()
	_cmd_inputs = [selection, _dynamic_cmd_items.duplicate(), self, _custom_commands]

	_base_instance_node = get_tree().root

	_update_var_inputs()
