@tool
extends Control
class_name CommandRunner

## Use print to output messages.
@export var print_output := true

## Use editor toast to output messages.
@export var toast_output := false

## Slightly more verbose messages.
@export var verbose_mode := false

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

var _dynamic_cmd_items := {}

var _save_path := ".godot/editor/cmd_runner.cfg"

var _cmd_inputs := []
var _cmd_input_names: PackedStringArray = []
var _base_cmd_input_names: PackedStringArray = []

var _base_instance_node: Node
var _last_result: Variant = null

var _custom_commands: CommandRunnerCustomCommands

func _ready() -> void:
	if is_part_of_edited_scene():
		return
	
	_custom_commands = CommandRunnerCustomCommands.new()
	_custom_commands.cmd_runner = self

	# todo code complete somehow
	#_cmd_input.code_completion_prefixes = [".", ",", "(", "=", "$", "@", "\"", "\'"]
	#_cmd_input.code_completion_requested.connect(_complete_request)

	_load_hist()
	_update_run_button_vis()
	_update_warning_label()

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
	_cmd_hist_index = -1
	
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
## returns [updated cmd text, awaitable, const cmd text portion ("" if none) ]
func _preprocess_cmd(cmd_text: String) -> Array:
	#print("processing `%s`" % cmd_text)
	var const_cmd_check_portion := cmd_text
	var awaitable := false
	if cmd_text.begins_with("await "):
		cmd_text = cmd_text.right(-6)
		awaitable = true
		const_cmd_check_portion = ""
	
	var cmd_split := cmd_text.split(" ", false)
	var func_name := cmd_split[0]
	var rest_of_cmd := cmd_text.split(" ", false, 1)[1] if cmd_split.size() > 1 else ""
	
	# Handle custom functions
	# Replace the first word with method implementation if it matches
	# This allows a command-like syntax while getting full parsing with Expression

	var method_list := _custom_commands.get_method_list()
	for method: Dictionary in method_list:
		var mname: String = method.name
		if not mname.begins_with("_cmd_") and not mname.begins_with("_cmdc_"):
			continue
		var is_func_const := false
		if mname.begins_with("_cmdc_"):
			is_func_const = true
		var prefix_width := -5 if not is_func_const else -6
		if mname.right(prefix_width) != func_name:
			continue
		#print(method)

		var rest_is_str := rest_of_cmd.strip_edges().begins_with("'") or rest_of_cmd.strip_edges().begins_with("\"")
		
		#var args := []
		var argcount := (method.args as Array).size()
		if argcount >= 1:
			if method.args[0].type == TYPE_STRING and not rest_is_str:
				# quote it
				var sep_at := rest_of_cmd.find(" ")
				if sep_at < 0 or rest_of_cmd.find(",") < sep_at:
					sep_at = rest_of_cmd.find(",")
				
				var first_arg := rest_of_cmd.substr(0, sep_at)
				rest_of_cmd = '"%s"%s' % [first_arg, rest_of_cmd.substr(sep_at)]
				# todo account for multiple? reliable?

			#args.push_back(rest_of_cmd)
		#if argcount >= 2:
			#args.push_back(cmd_split)
		#var argtext := ", ".join(args)
		var updated_cmd := "cmds.%s(%s)" % [mname, rest_of_cmd]
		var func_const_portion := updated_cmd
		if not is_func_const:
			func_const_portion = rest_of_cmd
		return [updated_cmd, awaitable, func_const_portion]

	return [cmd_text, awaitable, const_cmd_check_portion]

func _clear_editor_debugger() -> void:
	editor_debugger = null

func get_all_vars() -> Dictionary:
	return _dynamic_cmd_items

func has_var(var_name: String) -> bool:
	return _dynamic_cmd_items.has(var_name)

func get_var_value(var_name: String) -> Variant:
	return _dynamic_cmd_items[var_name]

func add_var(var_name: String, value: Variant) -> bool:
	if _base_cmd_input_names.has(var_name):
		outputerr("Invalid name `%s` overrides existing" % var_name)
		return false
	_dynamic_cmd_items[var_name] = value
	_update_inputs()
	return true

func remove_var(var_name: String) -> bool:
	if not _dynamic_cmd_items.has(var_name):
		outputerr("Cannot erase var `%s`, does not exist" % var_name)
		return false
	_dynamic_cmd_items.erase(var_name)
	_update_inputs()
	return true

func remove_all_vars() -> bool:
	_dynamic_cmd_items.clear()
	_update_inputs()
	return true

func _update_inputs() -> void:
	if editor_debugger == null:
		editor_debugger = EditorInterface.get_base_control().find_child("EditorDebugger", true, false)
		if editor_debugger != null and not editor_debugger.tree_exited.is_connected(_clear_editor_debugger):
			editor_debugger.tree_exited.connect(_clear_editor_debugger)

	_base_instance_node = null

	if editor_debugger != null:
		# get selected item
		if "_tree_view" not in editor_debugger or not editor_debugger.has_method("_get_node_from_view"):
			outputerr("EditorDebugger API changed")
			return

		# todo this isn't updated...
		@warning_ignore("unsafe_property_access", "unsafe_method_access", "untyped_declaration")
		var node_view = editor_debugger._tree_view.get_selected()
		@warning_ignore("unsafe_method_access")
		_base_instance_node = editor_debugger._get_node_from_view(node_view)

	# If multiple selections are needed, get in command on EditorInterface
	var selection := EditorInterface.get_selection().get_selected_nodes()[0] if not EditorInterface.get_selection().get_selected_nodes().is_empty() else null


	_cmd_inputs = [EditorInterface, selection, ClassDB, _dynamic_cmd_items.duplicate(), self, _custom_commands]
	_base_cmd_input_names = ["EditorInterface", "sel", "ClassDB", "allvars", "cmd_runner", "cmds"]
	_cmd_input_names = _base_cmd_input_names.duplicate()
	
	for dynamic_cmd_item_name: Variant in _dynamic_cmd_items:
		if not dynamic_cmd_item_name is String:
			outputerr("invalid dynamic cmd item %s" % dynamic_cmd_item_name)
			continue
		var cmd_name := dynamic_cmd_item_name as String
		_cmd_input_names.push_back(cmd_name)
		_cmd_inputs.push_back(_dynamic_cmd_items[cmd_name])


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

	if verbose_mode:
		output("Running cmd: `%s` on node `%s` (%s)" % [cmd_text, (_base_instance_node.name as String if _base_instance_node else "none"), (_base_instance_node.get_class() if _base_instance_node else "none")])
	var result: Variant = expr.execute(_cmd_inputs, _base_instance_node, true, false)
	if expr.has_execute_failed():
		outputerr("Exec failed: %s" % expr.get_error_text())
		return false

	if verbose_mode:
		output("cmd Result: `%s`" % [result])
	else:
		output("cmd %s `%s` = `%s`" % [_base_instance_node.name as String if _base_instance_node else "", cmd_text, result])
	_last_result = result
	return true

func _run_cmd(cmd_text: String) -> bool:
	var processed := _preprocess_cmd(cmd_text)
	cmd_text = processed[0]
	var await_result: bool = processed[1]
	if cmd_text.is_empty():
		return true
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

	if cmd_text.is_empty():
		check_exec[0] = false
		return "[color=yellow]No command[/color]"

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
		var _result: Variant = expr.execute(_cmd_inputs, _base_instance_node, false, true)
		if expr.has_execute_failed():
			check_exec[0] = false
			# TODO ignore const call errors. cannot check cause error message sucks rn https://github.com/godotengine/godot/pull/114216
			# "Method not const in const instance"
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
	
	var base_text := ("base: %s(%s)\n" % [_base_instance_node.name, _base_instance_node.get_class()]) if _base_instance_node else ""
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
			accept_event()
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
			accept_event()
		if kev.keycode == KEY_DOWN and at_bottom:
			if _cmd_hist_index >= _cmd_hist.size() - 1:
				# todo store wip text?
				_cmd_input.text = ""
				return
			_cmd_hist_index += 1
			assert(_cmd_hist_index < _cmd_hist.size() and _cmd_hist_index >= 0)
			_cmd_input.text = _cmd_hist[_cmd_hist_index]
			accept_event()


func _on_symbol_hovered(_symbol: String, _line: int, _column: int) -> void:
	pass # Replace with function body.
	# todo possible?
	#tooltip

func _complete_request() -> void:
	pass
	#var ctext = _cmd_input.get_text_for_code_completion()
	# Expression has no built in completion, so it would be a pain
	# gdscripts one isnt exposed either...
	
	#var gdscript_lang : ScriptLanguage
	#gdscript_lang.
	#update_code_completion_options(true)
	#GDScriptLanguageProtocol
	# todo the code complete popup would be in the way anyway since its not a popup

func _on_cmd_code_edit_symbol_validate(_symbol: String) -> void:
	_cmd_input.set_symbol_lookup_word_as_valid(true)

func _on_cmd_code_edit_symbol_lookup(symbol: String, _line: int, _column: int) -> void:
	var help_text := ""
	var target_object := _base_instance_node
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
