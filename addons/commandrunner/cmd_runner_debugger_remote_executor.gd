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
	print("CmdRunner debugger got message %s %s" % [message, data])
	if message == "run_cmd":
		if data.size() != 1 or data[0] is not String:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true

		_update_inputs()
		var cmd_txt := data[0] as String
		var worked := _run_expression(cmd_txt)
		send_message("cmd_finished", [OK, worked])
		return true
	if message == "set_selection":
		if data.size() != 1 or data[0] is not Object:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true
		selection = data[0] as Object
		return true
	if message == "set_base_node":
		if data.size() != 1 or data[0] is not Object:
			send_message("cmd_finished", [ERR_INVALID_DATA])
			return true
		_base_instance_node = data[0] as Object
		return true
	return false

func send_message(message: String, data: Array) -> void:
	EngineDebugger.send_message(message_prefix + ":" + message, data)

func output(output_text: String, is_escaped: bool = false) -> void:
	send_message("output", ["remote: " + output_text, is_escaped])

func outputerr(output_text: String) -> void:
	send_message("outputerr", ["remote: " + output_text])

func _update_inputs() -> void:
	_base_cmd_input_names = ["sel", "allvars", "cmd_runner", "cmds"]
	_cmd_input_names = _base_cmd_input_names.duplicate()
	_cmd_inputs = [selection, _dynamic_cmd_items.duplicate(), self, _custom_commands]

	_base_instance_node = get_tree().root

	_update_var_inputs()

func _run_expression(cmd_text: String) -> bool:
	var expr := Expression.new()
	var err := expr.parse(cmd_text, _cmd_input_names)
	if err != OK:
		outputerr("Parse error. cmd: `%s` error:%s %s" % [cmd_text, err, expr.get_error_text()])
		return false

	var base_instance := get_base_instance()
	if verbose_mode:
		output("Running cmd: `%s` on `%s`" % [cmd_text, CmdRunnerUtil.nice_print_obj(base_instance)])
	var result: Variant = expr.execute(_cmd_inputs, base_instance, true, false)
	if expr.has_execute_failed():
		outputerr("Exec failed: %s" % expr.get_error_text())
		return false

	if verbose_mode:
		output("cmd Result: `%s`" % [result])
	else:
		output("cmd %s `%s` = `%s`" % [CmdRunnerUtil.nice_print_obj(base_instance, false), cmd_text, result])
	#_last_result = result
	return true
