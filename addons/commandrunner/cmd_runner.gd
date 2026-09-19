@tool
extends CommandRunnerBase
class_name CommandRunner

## Use print to output messages.
@export var print_output := true

## Use editor toast to output messages.
@export var toast_output := false

## Execute commands detected as const when typing for better error messages.
@export var exec_const_on_type := true


@onready var _cmd_run_button: Button = %CmdRunButton
@onready var _cmd_input: CodeEdit = %CmdCodeEdit
@onready var _warning_label: RichTextLabel = %WarningLabel
@onready var _history_container: VBoxContainer = %HistoryContainer


var editor_debugger: Control

var _cmd_hist: PackedStringArray = []
var _cmd_hist_index := 0
var _max_hist_size := 100

var _save_path := ".godot/editor/cmd_runner.cfg"

var _last_result: Variant = null

func _ready() -> void:
	if is_part_of_edited_scene():
		return
	
	_custom_commands = CommandRunnerCustomCommands.new()
	_custom_commands.cmd_runner = self
	_custom_commands.cmd_runner_editor = self

	CmdRunnerEditorDebuggerHandler.get_singleton().cmd_runner = self

	#_cmd_input.code_completion_prefixes = [".", ",", "(", "=", "$", "@", "\"", "\'"]
	_cmd_input.code_completion_prefixes = [".", ",", "(", "=", "\"", "\'", ";"]
	_cmd_input.code_completion_requested.connect(_complete_request)

	_load_hist()
	_update_run_button_vis()
	_update_warning_label()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		remove_all_vars()

func _add_output_label(output_text: String) -> void:
	var new_label := RichTextLabel.new()
	new_label.name = "Cmd Hist _%s_" % output_text.left(5).validate_node_name()
	new_label.selection_enabled = true
	new_label.fit_content = true
	new_label.bbcode_enabled = true
	new_label.text = output_text
	_history_container.add_child(new_label)

	var hist_count := _history_container.get_child_count()
	var max_count := 10
	for i in range(hist_count - max_count):
		_history_container.get_child(i).queue_free()
	
	var scroll_container: ScrollContainer = _history_container.get_parent_control()

	# Scroll to end. just deferring isn't enough
	await get_tree().process_frame
	scroll_container.scroll_vertical = 10000

func clear_history() -> void:
	_cmd_hist = []
	_cmd_hist_index = 0

	clear_history_container()

func clear_history_container() -> void:
	var hist_count := _history_container.get_child_count()
	for i in range(hist_count):
		_history_container.get_child(i).queue_free()

	var scroll_container: ScrollContainer = _history_container.get_parent_control()
	scroll_container.scroll_vertical = 0


func output(output_text: String, is_escaped: bool = false) -> void:
	if toast_output:
		EditorInterface.get_editor_toaster().push_toast(output_text, EditorToaster.SEVERITY_INFO)
	if not is_escaped:
		output_text = _bbescape(output_text)
	_add_output_label("[color=gray]%s[/color]" % output_text)
	if print_output:
		print_rich(output_text)
		#print(output_text)

func outputerr(output_text: String) -> void:
	if toast_output:
		EditorInterface.get_editor_toaster().push_toast(output_text, EditorToaster.SEVERITY_ERROR)
	
	output_text = _bbescape(output_text)
	_add_output_label("[color=red]%s[/color]" % output_text)
	if print_output:
		printerr(output_text)

## preprocess the input text and determine if it should await or is const.
## returns [updated cmd text, awaitable, const cmd text portion ("" if none), remote ]
func _preprocess_cmd(cmd_text: String) -> Array:
	#print("processing `%s`" % cmd_text)
	cmd_text = cmd_text.strip_edges()
	var const_cmd_check_portion := cmd_text
	var awaitable := false
	var exec_on_remote := false
	if cmd_text.begins_with("await "):
		cmd_text = cmd_text.right(-6)
		awaitable = true
		const_cmd_check_portion = ""
		cmd_text = cmd_text.strip_edges()
	
	if cmd_text.begins_with("remote ") or cmd_text.begins_with("r "):
		cmd_text = cmd_text.right(-cmd_text.get_slice(" ", 0).length() - 1)
		exec_on_remote = true
		const_cmd_check_portion = ""
		cmd_text = cmd_text.strip_edges()
	
	var updated_cmd_text := cmd_text
	
	# Handle custom functions
	# Replace the first word with method implementation if it matches
	# This allows a command-like syntax while getting full parsing with Expression

	#var cmd_split := cmd_text.split(" ", false)
	#var func_name := cmd_split[0]
	var func_name := cmd_text.get_slice(" ", 0)
	var cmd_mi_list := get_all_cmds(exec_on_remote)
	var cmd_method: Dictionary
	for method: Dictionary in cmd_mi_list:
		var cmd_name: String = method.cmd_name
		if cmd_name != func_name:
			continue
		cmd_method = method

	if cmd_method.is_empty():
		return [updated_cmd_text, awaitable, const_cmd_check_portion, exec_on_remote]

	# found matching command
	#print(method)
	
	var mname: String = cmd_method.name
	var is_func_const: bool = cmd_method.const
	const_cmd_check_portion = ""

	var arg_text := ""
	if cmd_text.contains(" "):
		arg_text = cmd_text.split(" ", false, 1)[1].strip_edges()
	#print("arg_text `%s` cmd_text `%s` m %s" % [arg_text, updated_cmd_text, cmd_method])

	if arg_text.is_empty():
		# hopefully the cmd didn't need args
		updated_cmd_text = "cmds.%s()" % [mname]
		if is_func_const:
			const_cmd_check_portion = updated_cmd_text
		#print("empty ", updated_cmd_text)
		return [updated_cmd_text, awaitable, const_cmd_check_portion, exec_on_remote]
		

	var parser_codeedit := CodeEdit.new()
	parser_codeedit.queue_free()
	parser_codeedit.delimiter_strings = _cmd_input.delimiter_strings
	parser_codeedit.text = arg_text

	var needed_args := cmd_method.args as Array[Dictionary]
	var cur_needed_arg_index := 0
	var args := []
	var cur_paren_scope := 0
	var cur_brace_scope := 0
	var is_in_string_until := -1
	var cur_arg_start := 0
	for i in range(arg_text.length()):
		var c := arg_text[i]
		var prev_c := "" if i == 0 else arg_text[i - 1]
		#print("i %s `%s` narg:%s p%s"%[i, c, cur_needed_arg_index, cur_paren_scope])
		if i <= is_in_string_until:
			#print("skipping %s %s" %[i, c])
			continue
		if parser_codeedit.has_string_delimiter(c):
			#var d_in_str :=  parser_codeedit.is_in_string(cmd_line_caret_line, i + col_offset - 1)
			#print("i %s ofs %s instr %s" % [i, i + col_offset - 1, d_in_str])
			var str_end := parser_codeedit.get_delimiter_end_position(0, i + 1)
			if str_end.x == -1:
				# no end to string
				#print("no end to string")
				break
			var str_end_col: int = int(str_end.x) - 1
			#print("strstart %s i %s" % [str_end_col, i])
			is_in_string_until = str_end_col
			continue
		
		if cur_paren_scope == 0 and cur_brace_scope == 0:
			if c == "," or (c == " " and prev_c != " "):
				# going to next arg
				var cur_needed_arg: Dictionary
				if cur_needed_arg_index < needed_args.size():
					cur_needed_arg = needed_args[cur_needed_arg_index]
				
				#print(cur_needed_arg)
				# check when arg needs to be a string literal
				var quote_arg := (cur_needed_arg.get("type", -1) as int) == TYPE_STRING
				#quote_arg = quote_arg and (cur_needed_arg.get("name", "") as String).begins_with("l_")
				var cur_arg_text := arg_text.substr(cur_arg_start, i - cur_arg_start).strip_edges()
				if quote_arg:
					cur_arg_text = "\"%s\"" % cur_arg_text
				args.push_back(cur_arg_text)
				cur_arg_start = i + 1
				cur_needed_arg_index += 1
				continue

		if c == "(":
			cur_paren_scope += 1
		elif c == ")":
			cur_paren_scope -= 1
			if cur_paren_scope < 0:
				# out of scope
				break
		elif c == "[":
			cur_brace_scope += 1
		elif c == "]":
			cur_brace_scope -= 1
			if cur_brace_scope < 0:
				# out of scope
				break

	if cur_arg_start < arg_text.length():
		var cur_needed_arg: Dictionary
		if cur_needed_arg_index < needed_args.size():
			cur_needed_arg = needed_args[cur_needed_arg_index]
		# check when arg needs to be a string literal
		var quote_arg := (cur_needed_arg.get("type", -1) as int) == TYPE_STRING
		# add last arg
		var cur_arg_text := arg_text.substr(cur_arg_start).strip_edges()
		if quote_arg:
			cur_arg_text = "\"%s\"" % cur_arg_text
		args.push_back(cur_arg_text)

	var joined_args := ", ".join(args)
	updated_cmd_text = "cmds.%s(%s)" % [mname, joined_args]
	if is_func_const:
		const_cmd_check_portion = updated_cmd_text
	else:
		const_cmd_check_portion = joined_args

	return [updated_cmd_text, awaitable, const_cmd_check_portion, exec_on_remote]

func _clear_editor_debugger() -> void:
	editor_debugger = null

func _update_inputs() -> void:
	if editor_debugger == null:
		editor_debugger = EditorInterface.get_base_control().find_child("EditorDebugger", true, false)
		if editor_debugger != null and not editor_debugger.tree_exited.is_connected(_clear_editor_debugger):
			editor_debugger.tree_exited.connect(_clear_editor_debugger)

	_base_instance_node = null

	if editor_debugger != null:
		# get selected item
		if "_tree_view" in editor_debugger and editor_debugger.has_method("_get_node_from_view"):
			# old version
			@warning_ignore("unsafe_property_access", "unsafe_method_access", "untyped_declaration")
			var node_view = editor_debugger._tree_view.get_selected()
			@warning_ignore("unsafe_method_access")
			_base_instance_node = editor_debugger._get_node_from_view(node_view)
			@warning_ignore("unsafe_property_access", "unsafe_method_access")
		elif "_tree_view" in editor_debugger and editor_debugger._tree_view.has_method("get_selected_node"):
			@warning_ignore("unsafe_property_access", "unsafe_method_access")
			_base_instance_node = editor_debugger._tree_view.get_selected_node()
		else:
			if verbose_mode: outputerr("EditorDebugger API changed")

	# If multiple selections are needed, get in command on EditorInterface
	var selection := EditorInterface.get_selection().get_selected_nodes()[0] if not EditorInterface.get_selection().get_selected_nodes().is_empty() else null

	_cmd_inputs = [selection, _dynamic_cmd_items.duplicate(), self, _custom_commands]
	_base_cmd_input_names = ["sel", "allvars", "cmd_runner", "cmds"]
	_cmd_input_names = _base_cmd_input_names.duplicate()

	_update_var_inputs()

func _run_expression(cmd_text: String) -> bool:
	#if not _base_instance_node:
		# Not needed, no selection is fine
		#outputerr("No node selected. cmd: `%s`" % [cmd_text])
		#return false
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
	_last_result = result
	return true

func _run_cmd(cmd_text: String) -> bool:
	var processed := _preprocess_cmd(cmd_text)
	cmd_text = processed[0]
	if cmd_text.is_empty():
		return true
	var await_result: bool = processed[1]
	var remote: bool = processed[3]
	if remote:
		var handler := CmdRunnerEditorDebuggerHandler.get_singleton()
		if not handler.is_active():
			outputerr("Cannot send remote cmd, session not active")
			return false
		await handler.send_message_and_wait("run_cmd", [cmd_text])
		var remote_success: Error = handler.response_data[0]
		if remote_success != OK:
			outputerr("Remote failed %s" % error_string(remote_success))
			return false
		if verbose_mode:
			output("Remote success %s" % [handler.response_data])
		if handler.response_data.size() < 2:
			outputerr("Remote invalid response %s" % handler.response_data)
			return false
		var remote_worked: bool = handler.response_data[1]
		return remote_worked
	var worked := _run_expression(cmd_text)
	if worked and await_result:
		await _last_result
	return worked

func _run_cmds() -> void:
	var cmd_txt := _cmd_input.text
	if cmd_txt.strip_edges().is_empty():
		outputerr("No cmd to execute!")
		return

	# save cmd history
	if _cmd_hist.is_empty() or _cmd_hist[_cmd_hist.size() - 1] != cmd_txt:
		#_cmd_hist = _cmd_hist.filter(func (a): return _cmd_hist.count(a) == 1)
		for i: int in max(0, _cmd_hist.size() - _max_hist_size):
			_cmd_hist.remove_at(0)
		_cmd_hist.push_back(cmd_txt)
		_cmd_hist_index = _cmd_hist.size() - 1
		# clear if different type? idk
		# dont save if already the same as other previous commands? move old commands instead of re-adding?
	
	_update_inputs()
	#verbose_mode = true

	var cmds := cmd_txt.strip_edges().replace(";", "\n").split("\n", false)
	
	#print("running commands")
	for cmd in cmds:
		cmd = cmd.strip_edges()
		if cmd.is_empty():
			continue
		if not await _run_cmd(cmd):
			# a command failed, end
			break

	_save_hist()
	
	# todo open output dock?

func _bbescape(s: String) -> String:
	return s.replace("[", "[lb]")

func _check_expression(cmd_text: String, check_exec: Array) -> String:
	var processed := _preprocess_cmd(cmd_text)
	cmd_text = processed[0]
	#var await_result : bool = processed[1]
	var const_portion: String = processed[2]
	var exec_on_remote: bool = processed[3]

	if cmd_text.is_empty():
		check_exec[0] = false
		return "[color=yellow]No command[/color]"

	if exec_on_remote:
		var handler := CmdRunnerEditorDebuggerHandler.get_singleton()
		# this can change without us knowing, so dont err
		if not handler.is_active():
			return "[color=red]No active remote session[/color] `%s`" % _bbescape(cmd_text)
		return "Remote cmd `%s`" % _bbescape(cmd_text)

	if const_portion.is_empty():
		check_exec[0] = false
		return "[color=gray][i]Non-const, skipping exec checks[/i][/color] `%s`" % _bbescape(cmd_text)
	
	var expr := Expression.new()
	var err := expr.parse(const_portion, _cmd_input_names)
	if err != OK:
		check_exec[0] = false
		return "[color=red]Parse Error:[/color] %s; %s `%s`" % [error_string(err), _bbescape(expr.get_error_text()), _bbescape(const_portion)]
	
	if not check_exec[0]:
		# warning was already printed
		return ""
	
	if exec_const_on_type:
		# NOTE: gdscript doesn't have const calls so this can change things...
		var _result: Variant = expr.execute(_cmd_inputs, get_base_instance(), false, true)
		if expr.has_execute_failed():
			check_exec[0] = false
			# TODO ignore const call errors. cannot check cause error message sucks rn https://github.com/godotengine/godot/pull/114216
			# "Method not const in const instance"

			# These errors may show when using a class that isn't in the inputs.
			var err_msgs_missing_class := ["self can't be used ", "Invalid named index"]
			for missing_msg: String in err_msgs_missing_class:
				var err_text := expr.get_error_text()
				if err_text.contains(missing_msg):
					var update := _auto_add_class(const_portion)
					if update:
						# Re-update
						_update_warning_label.call_deferred()
					break

			return "[color=red]Error:[/color] %s `%s`" % [_bbescape(expr.get_error_text()), _bbescape(const_portion)]

	#return ""
	return "[color=darkgreen]%s[/color]" % _bbescape(cmd_text)

func _update_warning_label() -> void:
	var cmd_txt := _cmd_input.text
	_update_inputs()
	var cmds := cmd_txt.strip_edges().replace(";", "\n").split("\n", false)
	
	var warnings := []

	var check_ref := [true]
	for cmd in cmds:
		cmd = cmd.strip_edges()
		if cmd.is_empty():
			continue
		warnings.push_back(_check_expression(cmd, check_ref))
	
	if cmds.is_empty():
		_warning_label.hide()
		return
	
	_warning_label.show()
	
	var warning_text := "\n".join(warnings)
	if warning_text.is_empty():
		_warning_label.text = "[color=green]Valid[/color]"
		return
	
	var base_text := "base: %s\n" % [CmdRunnerUtil.nice_print_obj(get_base_instance())]
	if get_base_instance() == null:
		base_text = ""
	#_warning_label.text = "[color=red]"+warnings+"[/color]"
	_warning_label.text = "%s%s" % [base_text, warning_text]

func _on_cmd_run_button_pressed() -> void:
	_run_cmds()

func _load_hist() -> void:
	var savecfg := ConfigFile.new()
	var err := savecfg.load(_save_path)
	if err != OK:
		#print("Command Runner failed to load cfg ", error_string(err))
		return
	var hist: Variant = savecfg.get_value("cmds", "_cmd_hist")
	_cmd_hist = hist
	_cmd_hist_index = -1
	#text = hist

func _save_hist() -> void:
	var savecfg := ConfigFile.new()
	var err := savecfg.load(_save_path)
	if err == ERR_FILE_NOT_FOUND:
		pass
		# make new one
		#print("Command Runner making new confg file %s" % _save_path)
	elif err != OK:
		printerr("Command Runner failed to open cfg file '%s'!" % _save_path, err)
		return

	#var prev_hist = savecfg.get_value("cmds", "cmd")
	savecfg.set_value("cmds", "_cmd_hist", _cmd_hist)
	savecfg.save(_save_path)


func _on_text_changed() -> void:
	if is_part_of_edited_scene():
		return
	_update_run_button_vis()
	_update_warning_label()

func _update_run_button_vis() -> void:
	_cmd_run_button.visible = not _cmd_input.text.strip_edges().is_empty()

	#if not _cmd_hist.is_empty():
		#_cmd_hist_index = _cmd_hist.size() - 1
	
	# Control s x "plugin.gd"
	#if _cmd_run_button.visible:
		#var savecfg := ConfigFile.new()
		#savecfg.set_value("_cmd_hist", "cmd", text.strip_edges())
		#savecfg.save(_save_path)

func _on_gui_input(event: InputEvent) -> void:
	if is_part_of_edited_scene():
		return
	var kev := event as InputEventKey
	if kev and not kev.is_echo() and kev.pressed:
		if kev.keycode == KEY_ENTER and not kev.is_command_or_control_pressed():
			_run_cmds()
			_cmd_input.accept_event()
		# todo cannot use normal key up...
		var c_line := _cmd_input.get_caret_line()
		var c_col := _cmd_input.get_caret_column()
		var line_count := _cmd_input.get_line_count()
		var at_top := line_count == 0 or (c_line == 0 and c_col == 0)
		var at_bottom := line_count == 0 or (c_line == line_count - 1 and _cmd_input.get_line_wrap_index_at_column(c_line, c_col) == _cmd_input.get_line_wrap_count(c_line))
		if kev.keycode == KEY_UP and at_top:
			if _cmd_hist_index == 0:
				return
			#print("up ", _cmd_hist_index, text, " ", _cmd_hist[_cmd_hist_index])
			if _cmd_hist_index < 0:
				_cmd_hist_index = _cmd_hist.size() - 1
			if _cmd_input.text == _cmd_hist[_cmd_hist_index]:
				_cmd_hist_index -= 1
			assert(_cmd_hist_index < _cmd_hist.size() and _cmd_hist_index >= 0)
			_cmd_input.text = _cmd_hist[_cmd_hist_index]
			_cmd_input.accept_event()
		if kev.keycode == KEY_DOWN and at_bottom:
			if _cmd_hist_index >= _cmd_hist.size() - 1:
				# todo store wip text?
				_cmd_input.text = ""
				return
			_cmd_hist_index += 1
			assert(_cmd_hist_index < _cmd_hist.size() and _cmd_hist_index >= 0)
			_cmd_input.text = _cmd_hist[_cmd_hist_index]
			_cmd_input.accept_event()


func _on_symbol_hovered(_symbol: String, _line: int, _column: int) -> void:
	pass # Replace with function body.
	# todo possible?
	#tooltip

func _complete_request() -> void:
	# Expression has no built in completion, so its a pain
	# gdscripts one isnt exposed either...
	var completion_debug := false
	
	var upreprocessed_cmds := _cmd_input.get_text_for_code_completion()
	upreprocessed_cmds = upreprocessed_cmds.replace(";", "\n")
	var unp_split := upreprocessed_cmds.split("\n")
	var upreprocessed_cmd := ""
	for unp_spliti in unp_split:
		if char(0xFFFF) in unp_spliti:
			upreprocessed_cmd = unp_spliti
			break
	upreprocessed_cmd = upreprocessed_cmd.strip_edges()
	
	if upreprocessed_cmd.is_empty():
		printerr("CmdRunner completion failed to extract cmd `%s`" % upreprocessed_cmds)
		return
	
	var preprocessed := _preprocess_cmd(upreprocessed_cmd)
	var preprocessed_full_text: String = preprocessed[0]
	var preprocessed_cmd_text: String = preprocessed[2]
	var is_remote_cmd: bool = preprocessed[3]
	if completion_debug:
		print("completion preprocessed: `%s` full: `%s`" % [preprocessed_cmd_text, preprocessed_full_text])
	
	var cmd_column := preprocessed_cmd_text.find(char(0xFFFF))
	var cmd_text := preprocessed_cmd_text.remove_char(0xFFFF)
	var cmd_before_text := cmd_text.left(cmd_column)
	if completion_debug: print("code completion on `%s` col %s, `%s`" % [cmd_text, cmd_column, cmd_before_text])
	if cmd_column < 0:
		cmd_column = 0
	assert(cmd_column >= 0 and cmd_column <= cmd_text.length())
	
	var parser_codeedit := CodeEdit.new()
	parser_codeedit.queue_free()
	parser_codeedit.delimiter_strings = _cmd_input.delimiter_strings
	#parser_codeedit.delimiter_comments
	parser_codeedit.text = cmd_before_text

	
	if parser_codeedit.is_in_comment(0, cmd_column) != -1:
		printerr("CmdRunner expression in comment")
		return
	if parser_codeedit.is_in_string(0, cmd_column) != -1:
		#var str_start := parser_codeedit.get_delimiter_start_position(cmd_line_caret_line, cmd_line_column)
		#print("CmdRunner expression in string")
		# todo different options?
		return

	# find start of relevant section
	var section_start := cmd_column
	var cur_word_start := cmd_column
	var found_word_start := false
	var cur_paren_scope := 0
	var cur_brace_scope := 0
	var is_in_string_until := -1
	
	for i in range(cmd_before_text.length() - 1, -1, -1):
		var c := cmd_before_text[i]
		var symb := is_symbol(c)
		#print("i %s `%s` symb %s sect %s word %s str %s br %s" %[i,c,symb,section_start,cur_word_start, is_in_string_until, cur_brace_scope])
		if not found_word_start:
			if symb:
				found_word_start = true
			else:
				cur_word_start = i

		if is_in_string_until >= 0 and i >= is_in_string_until:
			#print("skipping %s %s" %[i, c])
			continue
		if parser_codeedit.has_string_delimiter(c):
			#var d_in_str :=  parser_codeedit.is_in_string(cmd_line_caret_line, i + col_offset - 1)
			#print("i %s ofs %s instr %s" % [i, i + col_offset - 1, d_in_str])
			var str_start := parser_codeedit.get_delimiter_start_position(0, i - 1)
			if str_start.x == -1:
				printerr("CmdRunner no end to string! %s" % i)
				break
			var str_start_col: int = int(str_start.x) - 1
			#print("strstart %s i %s" % [str_start_col, i])
			is_in_string_until = str_start_col
			section_start = is_in_string_until
			continue

		if c == ",":
			# going to a prev param
			break
		elif c == ")":
			cur_paren_scope += 1
		elif c == "(":
			cur_paren_scope -= 1
			if cur_paren_scope < 0:
				# out of scope
				break
		elif c == "]":
			cur_brace_scope += 1
		elif c == "[":
			cur_brace_scope -= 1
			if cur_brace_scope < 0:
				# out of scope
				break
		section_start = i
	
	
	var complete_section := cmd_before_text if section_start == 0 else cmd_before_text.right(-section_start)
	var cur_word := cmd_before_text if cur_word_start == 0 else cmd_before_text.right(-cur_word_start)
	var parsable_section := complete_section.trim_suffix(cur_word)
	if parsable_section.ends_with("."):
		parsable_section = parsable_section.left(-1)
	
	if completion_debug: print("section `%s` (%s) word `%s` (%s) p `%s`" % [complete_section, section_start, cur_word, cur_word_start, parsable_section])
	
	var base_result: Variant = null
	if not parsable_section.is_empty():
		_update_inputs()
		var expr := Expression.new()
		var err := expr.parse(parsable_section, _cmd_input_names)
		if err != OK:
			if completion_debug: print("completion Parse error. cmd: `%s` error:%s %s" % [cmd_text, err, expr.get_error_text()])
			return
		
		var base_instance := get_base_instance()
		# hopefully its actually const...
		base_result = expr.execute(_cmd_inputs, base_instance, false, true)
		if expr.has_execute_failed():
			if completion_debug: print("completion Exec failed: %s" % expr.get_error_text())
			return
		if completion_debug: print("completion exec success `%s`" % base_result)
	
	var result_items := []
	
	const keywords: PackedStringArray = ["await", "remote"]

	if base_result == null:
		# all vars and cmds
		for keyword_name in keywords:
			result_items.push_back({
				"insert": keyword_name,
				"kind": CodeEdit.CodeCompletionKind.KIND_KEYWORD,
				"location": CodeEdit.CodeCompletionLocation.LOCATION_OTHER_USER_CODE,
			})
			
		var all_cmds := get_all_cmds(is_remote_cmd)
		for cmd_mi: Dictionary in all_cmds:
			result_items.push_back({
				"insert": cmd_mi["cmd_name"],
				"kind": CodeEdit.CodeCompletionKind.KIND_FUNCTION,
				"cmd": true,
				"location": CodeEdit.CodeCompletionLocation.LOCATION_OTHER_USER_CODE,
			})
		var all_vars := get_all_vars().keys()
		for inp_name in _cmd_input_names:
			var is_var := all_vars.has(inp_name)
			result_items.push_back({
				"insert": inp_name,
				"kind": CodeEdit.CodeCompletionKind.KIND_VARIABLE if is_var else CodeEdit.CodeCompletionKind.KIND_CLASS,
				"location": CodeEdit.CodeCompletionLocation.LOCATION_PARENT_MASK | 1,
			})
			
		pass
	elif base_result is Object:
		var base_obj := base_result as Object
		var props := base_obj.get_property_list()
		for prop: Dictionary in props:
			# todo not correct?
			if not prop["usage"] & PROPERTY_USAGE_STORAGE:
				continue
			result_items.push_back({
				"insert": prop["name"],
				"kind": CodeEdit.CodeCompletionKind.KIND_MEMBER,
				"location": CodeEdit.CodeCompletionLocation.LOCATION_LOCAL,
			})
		var methods := base_obj.get_method_list()
		for method: Dictionary in methods:
			#todo check return type and prioritize?
			#if not method["usage"] & PROPERTY_USAGE_STORAGE:
			#	continue
			result_items.push_back({
				"insert": method["name"],
				"display_name": method["name"] + "()",
				"kind": CodeEdit.CodeCompletionKind.KIND_FUNCTION,
				"location": CodeEdit.CodeCompletionLocation.LOCATION_LOCAL,
			})
	#if base_result is String:
		# get_argument_options() is not exposed!
		#String().

	if completion_debug: print("items ", result_items)
	
	if result_items.is_empty():
		return
	
	for result_item: Dictionary in result_items:
		var ckind: CodeEdit.CodeCompletionKind = result_item["kind"]
		var insert: String = result_item["insert"]
		var display_name: String = result_item.get("display_name", insert)
		var location: CodeEdit.CodeCompletionLocation = result_item.get("location", CodeEdit.CodeCompletionLocation.LOCATION_OTHER)
		var cmd: bool = result_item.get("cmd", false)
		var icon := _get_completion_icon(ckind, display_name, cmd)
		_cmd_input.add_code_completion_option(ckind, display_name, insert, Color.WHITE, icon, null, location)
	_cmd_input.update_code_completion_options(false)

# CodeTextEditor::_get_completion_icon
func _get_completion_icon(kind: CodeEdit.CodeCompletionKind, display: String, cmd: bool) -> Texture2D:
	var tex: Texture2D
	if cmd:
		#return _cmd_input.get_theme_icon("FadeDisabled" , "EditorIcons")
		return _cmd_input.get_theme_icon("GuiTreeArrowRight", "EditorIcons")
	match kind:
		CodeEdit.CodeCompletionKind.KIND_CLASS:
			var formatted_class_name := display # todo needed? .unquote();
			if _cmd_input.has_theme_icon(formatted_class_name, "EditorIcons"):
				tex = _cmd_input.get_theme_icon(formatted_class_name, "EditorIcons");
			else:
				# todo
				#tex = EditorNode::get_singleton()->get_class_icon(formatted_class_name);
				if tex == null:
					tex = _cmd_input.get_theme_icon("Object", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_ENUM:
			tex = _cmd_input.get_theme_icon("Enum", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_FILE_PATH:
			tex = _cmd_input.get_theme_icon("File", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_NODE_PATH:
			tex = _cmd_input.get_theme_icon("NodePath", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_VARIABLE:
			tex = _cmd_input.get_theme_icon("LocalVariable", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_CONSTANT:
			tex = _cmd_input.get_theme_icon("MemberConstant", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_MEMBER:
			tex = _cmd_input.get_theme_icon("MemberProperty", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_SIGNAL:
			tex = _cmd_input.get_theme_icon("MemberSignal", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_FUNCTION:
			tex = _cmd_input.get_theme_icon("MemberMethod", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_KEYWORD:
			tex = _cmd_input.get_theme_icon("Keyword", "EditorIcons");
		CodeEdit.CodeCompletionKind.KIND_PLAIN_TEXT:
			tex = _cmd_input.get_theme_icon("BoxMesh", "EditorIcons");
		_:
			tex = _cmd_input.get_theme_icon("String", "EditorIcons");
	return tex

func _on_cmd_code_edit_symbol_validate(_symbol: String) -> void:
	_cmd_input.set_symbol_lookup_word_as_valid(true)

func _on_cmd_code_edit_symbol_lookup(symbol: String, _line: int, _column: int) -> void:
	var help_text := ""
	var target_object := get_base_instance()
	if target_object == null:
		var sels := EditorInterface.get_selection().get_selected_nodes()
		if sels:
			target_object = sels[0]
	
	if ClassDB.class_exists(symbol):
		help_text = "class_name:%s" % symbol
	elif ClassDB.class_has_method("@GlobalScope", symbol):
		help_text = "class_method:@GlobalScope:%s" % symbol
	if target_object != null:
		# todo get parent class with the symbol
		#var target_class := target_object.get_class()
		#if symbol in ClassDB.class_get_property_list(target_class):
		if target_object.has_method(symbol):
			help_text = "class_method:%s:%s" % [target_object.get_class(), symbol]
		elif target_object.has_signal(symbol):
			help_text = "class_signal:%s:%s" % [target_object.get_class(), symbol]
		elif symbol in target_object:
			# or constant?
			help_text = "class_property:%s:%s" % [target_object.get_class(), symbol]
		
	EditorInterface.get_script_editor().goto_help(help_text)
