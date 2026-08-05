@tool
extends Control
class_name CommandRunner

@onready var cmd_run_button: Button = %CmdRunButton
@onready var cmd_input: CodeEdit = %CmdCodeEdit
@onready var warning_label: RichTextLabel = %WarningLabel
@onready var history_container: VBoxContainer = %HistoryContainer

var editor_debugger: Control

class SignalTracker extends RefCounted:
	var vname := ""
	var name := "unknown signal"
	var obj_name := "unknown obj"
	var cmd_runner : CommandRunner = null
	
	func report(...args):
		var s := "%s: Signal `%s` emitted on `%s` with args `%s`" % [vname, name, obj_name, args]
		#if cmd_runner != null:
			## should this use output func? it can happen any time
			#cmd_runner._output(s)
		#else:
			#print(s)
		print(s)

var cmd_state := []

var cmd_hist := []
var cmd_hist_index := 0
var max_hist_size := 100

var dynamic_cmd_items := {}

var save_path := ".godot/editor/cmd_runner.cfg"

var cmd_inputs := []
var base_cmd_input_names := []
var cmd_input_names := []

var base_instance_node : Node

var last_result = null

var current_command_text := ""
var command_non_constant := false
var command_await := false

@export
var print_output := true
@export
var toast_output := false
@export
var verbose_mode := false

func _ready() -> void:
	if is_part_of_edited_scene():
		return


	#cmd_input.code_completion_prefixes = [".", ",", "(", "=", "$", "@", "\"", "\'"]
	#cmd_input.code_completion_requested.connect(_complete_request)

	_load_hist()
	_update_run_button_vis()
	_update_warning_label()

func _add_output_label(output_text: String):
	var new_label := RichTextLabel.new()
	new_label.name = "Cmd Hist _%s_" % output_text.left(5).validate_node_name()
	new_label.selection_enabled = true
	new_label.fit_content = true
	new_label.bbcode_enabled = true
	new_label.text = output_text
	history_container.add_child(new_label)

	var hist_count := history_container.get_child_count()
	var max_count := 10
	for i in range(hist_count - max_count):
		history_container.get_child(i).queue_free()
	
	var scroll_container : ScrollContainer = history_container.get_parent_control()

	# Scroll to end. just deferring isn't enough
	await get_tree().process_frame
	scroll_container.scroll_vertical = 10000
	#scroll_container.set_v_scroll.call_deferred(10000)

func _output(output_text: String, verbose := false):
	if toast_output:
		EditorInterface.get_editor_toaster().push_toast(output_text, EditorToaster.SEVERITY_INFO)
	_add_output_label("[color=gray]%s[/color]" % output_text)
	if print_output:
		print_rich(output_text)
		#print(output_text)

func _outputerr(output_text: String, verbose := false):
	if toast_output:
		EditorInterface.get_editor_toaster().push_toast(output_text, EditorToaster.SEVERITY_ERROR)
	
	_add_output_label("[color=red]%s[/color]" % output_text)
	if print_output:
		printerr(output_text)


#region custom commands

## all functions that start with _cmd_ can be run by typing the rest of the function name. No parenthesis 
## these may take parameters, comma separated
## _cmdc are constant and will be executed before submitting

## hi
func _cmdc_test():
	print("test method")

func _cmdc_help():
	var cmds := []
	for method in get_method_list():
		var mname: String = method.name
		var cmd_name := ""
		if mname.begins_with("_cmd_"):
			cmd_name = mname.right(-5)
		elif mname.begins_with("_cmdc_"):
			cmd_name = mname.right(-6)
		else:
			continue
		
		#(method.args as Array).reduce(func(acc, val): return val.name)
		var names := (method.args as Array).map(func(val): return val.name)
		if not names.is_empty():
			cmd_name += "(" + ",".join(names) + ")"
		
		# get descriptions by parsing the file?
		var source := (get_script() as Script).source_code
		var method_at := source.find(mname)
		if method_at >= 0:
			var doc_start_at := method_at - 7 # `\nfunc ` -1
			while doc_start_at >= 0:
				var prev_line := source.rfind("\n", doc_start_at)
				#if mname.ends_with("test"): print("'"+source.substr(prev_line+1, doc_start_at-prev_line)+"'")
				if prev_line >= 0 and source.substr(prev_line+1, doc_start_at-prev_line).strip_edges().begins_with("##"):
					doc_start_at = prev_line-1
				else:
					break
			if doc_start_at != method_at - 7:
				var docs := source.substr(doc_start_at,method_at-doc_start_at - 6).replace("\n", " ").remove_chars("#").strip_edges()
				cmd_name += " [color=cyan][i]%s[/i][/color]" % docs

		cmds.push_back(cmd_name)

	_output("help\ncmds:\n%s\ninputs: %s\nvars: %s" % ["\n".join(cmds), cmd_input_names, dynamic_cmd_items])
	

func _cmd_q():
	verbose_mode = not verbose_mode
	_output("verbose mode %s" % verbose_mode, true)
	return true

## toggl toast output
func _cmd_toast():
	toast_output = not toast_output
	_output("toast_output %s" % toast_output, true)

func _cmd_cls():
	cmd_hist = []
	cmd_hist_index = -1
	# todo how to not add cls to list?

func _cmd_docs(target : Object):
	if target == null:
		_outputerr("No target!")
		return false
	# todo test
	EditorInterface.get_script_editor().goto_help("class_name:%s" % target.get_class())

## open a new floating inspector
func _cmd_inspect(target : Object):
	#if last_result !=null and  last_result is Object:
		#target = last_result
	#if target == null:
		#_run_expression("self")
		#if last_result is Object:
			#target = last_result
	if target == null:
		_outputerr("No target Object to inspect!")
		return false
	_output("inspecting %s" % target)
	_open_in_new_inspector(target)
	return true

## create a new instance of a class. Useful if you need access to something from the editor, like JSON # todo can be automatic?
func _cmd_new(var_name: String, opt_class_name:=""):
	var new_class_name := var_name
	if opt_class_name != "":
		new_class_name = opt_class_name

	var made_new := true
	var new_class = null
	if Engine.has_singleton(new_class_name):
		new_class = Engine.get_singleton(new_class_name)
		made_new = false
	elif ClassDB.can_instantiate(new_class_name):
			# make var instead
		new_class = ClassDB.instantiate(new_class_name);
	#elif ClassDB.class_exists(new_class_name):
		#new_class = ClassDB.class_call_static()
	if new_class == null:
		_outputerr("Cannot make class %s" % new_class_name)
		return false
	_make_var(var_name, new_class)
	if made_new:
		_output("made new class %s %s" % [var_name, new_class_name])
	else:
		_output("got class %s %s" % [var_name, new_class_name])
	return true

## create a new variable `var name value`
func _cmd_var(var_name: String, value):
	if base_cmd_input_names.has(var_name):
		_outputerr("Invalid name `%s` overrides existing" % var_name)
		return false
	var prefix_action := "Updated" if dynamic_cmd_items.has(var_name) else "Saved"
	_make_var(var_name, value, true)
	_output("%s var `%s` to value `%s`" % [prefix_action, var_name, value], true)
	return true

func _make_var(saved_name: String, value, overwrite:=false):
	if not overwrite and base_cmd_input_names.has(saved_name):
		_outputerr("Invalid name `%s` overrides existing" % saved_name)
		return false
	dynamic_cmd_items[saved_name] = value
	_update_inputs()

func _cmd_erase(var_name: String):
	if not dynamic_cmd_items.has(var_name) and var_name != "allvars":
		_outputerr("Cannot erase var `%s`, does not exist" % var_name)
		return false
	if var_name == "allvars":
		# erase all
		dynamic_cmd_items.clear()
		_output("Erased allvars")
		_update_inputs()
		return true
	var prev_dyn_value = dynamic_cmd_items[var_name]
	dynamic_cmd_items.erase(var_name)
	_update_inputs()
	_output("Erased var `%s`, previously %s" % [var_name, prev_dyn_value])
	return true


func _cmd_track(signame: String, target_obj : Object = null):

	if target_obj == null:
		target_obj = base_instance_node

	if target_obj == null or not target_obj.has_signal(signame):
		_outputerr("Cannot track signal `%s` on object `%s`: not found" % [signame, "null" if not target_obj else target_obj.name])
		return true

	#var siglist := target_obj.get_signal_list()
	#for sig in siglist:
		#if sig["name"] != signame:
			#return
		#for arg in sig["args"]:

	var targ_name := ""
	if target_obj is Node:
		targ_name = target_obj.name
	elif target_obj is Resource:
		targ_name = "%s-%s" % [target_obj.get_class(),  target_obj.get_rid()]
	else:
		targ_name = "%s-r%s" % [target_obj.get_class(), randi() % 10000]
	var vname := "track_%s_%s"% [signame, targ_name]
	var sig_tracker := SignalTracker.new()
	sig_tracker.vname = vname
	sig_tracker.name = signame
	sig_tracker.obj_name = targ_name
	sig_tracker.cmd_runner = self
	target_obj.connect(signame, sig_tracker.report)
	dynamic_cmd_items[vname] = sig_tracker
	_output("Tracking signal `%s` on `%s`" % [vname, targ_name])
	_update_inputs()
	return true

func _cmd_trackclear(signame: String, target_obj : Object = null):
	var to_rem := []
	if signame != "":
		pass
		if target_obj == null:
			target_obj = base_instance_node
		if target_obj == null or not target_obj.has_signal(signame):
			_outputerr("Cannot trackclear signal `%s` on object `%s`: not found" % [signame, "null" if not target_obj else target_obj.name])
			return true
		var targ_name := ""
		if target_obj is Node:
			targ_name = target_obj.name
		elif target_obj is Resource:
			targ_name = "%s-%s" % [target_obj.get_class(),  target_obj.get_rid()]
		else:
			targ_name = "%s-r%s" % [target_obj.get_class(), randi() % 10000]
		var vname := "track_%s_%s"% [signame, targ_name]
		if not dynamic_cmd_items.has(vname):
			_outputerr("Cannot trackclear signal `%s`: not found" % [vname])
			return true
		dynamic_cmd_items.erase(vname)
	else:
		for dci_name in dynamic_cmd_items:
			var val = dynamic_cmd_items[dci_name]
			if val is SignalTracker:
				to_rem.push_back(val)
	for v in to_rem:
		dynamic_cmd_items.erase(v)
	_update_inputs()
	_output("cleared signal trackings")
	return true

func _cmd_focus_on(target : Node):
	if target != null and editor_debugger != null:
		editor_debugger._focus_in_tree(target)
	return true

#endregion

#unused, preprocess instead
#func _run_func(cmd_text: String) -> bool:
	#var cmd_split := cmd_text.split(" ", false)
	#var func_name := cmd_split[0]
	#var rest_of_cmd := cmd_text.split(" ", false, 1)[1] if cmd_split.size() > 1 else ""
	#
	#for method in get_method_list():
		#var mname: String = method.name
		#if not mname.begins_with("_cmd_"):
			#continue
		#if not mname.right(-5) == func_name:
			#continue
		#var args := []
		#var argcount := (method.args as Array).size()
		#if argcount >= 1:
			#args.push_back(rest_of_cmd)
		#if argcount >= 2:
			#args.push_back(cmd_split)
		#var ret := await callv(mname, args)
		#return true
#
	## todo preprocess instead of calling manually?
	## error msgs will be affected, but its probably fine
	## change "var a b" to "cmd_runner._ cmd_var(a,b)" etc
	## rework them to not need text to parse or last result at all. would also help with consistency
	## then it can parse as expression
	## separate script too maybe?
	## but may need a 'const' flag for it
	## alternative is to strip valid funcs from parse checking and only maybe parse next part
#
	#return false

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
	
	# handle custom functions
	for method : Dictionary in get_method_list():
		var mname: String = method.name
		if not mname.begins_with("_cmd_") and not mname.begins_with("_cmdc_"):
			continue
		var is_func_const := false
		if mname.begins_with("_cmdc_"):
			is_func_const = true
		var prefix_width := -5 if not is_func_const else -6
		if mname.right(prefix_width) != func_name:
			continue
		
		var rest_is_str := rest_of_cmd.strip_edges().begins_with("'") or rest_of_cmd.strip_edges().begins_with("\"")
		
		#var args := []
		var argcount := (method.args as Array).size()
		if argcount >= 1:
			if method.args[0].type == TYPE_STRING and not rest_is_str:
				# quote it
				var sep_at := rest_of_cmd.find(" ")
				if sep_at < 0 or rest_of_cmd.find(",") < sep_at:
					sep_at = rest_of_cmd.find(",")
				
				var first_arg = rest_of_cmd.substr(0,sep_at)
				rest_of_cmd = '"%s"%s' % [first_arg, rest_of_cmd.substr(sep_at)]
				# todo account for multiple? reliable?

			#args.push_back(rest_of_cmd)
		#if argcount >= 2:
			#args.push_back(cmd_split)
		#var argtext := ", ".join(args)
		var updated_cmd := "cmd_runner.%s(%s)" % [mname, rest_of_cmd]
		var func_const_portion := updated_cmd
		if not is_func_const:
			func_const_portion = rest_of_cmd
		return [updated_cmd, awaitable, func_const_portion]

	return [cmd_text, awaitable, const_cmd_check_portion]

func _clear_editor_debugger():
	editor_debugger = null

func _update_inputs():
	if editor_debugger == null:
		editor_debugger = EditorInterface.get_base_control().find_child("EditorDebugger", true, false)
		if editor_debugger != null and not editor_debugger.tree_exited.is_connected(_clear_editor_debugger):
			editor_debugger.tree_exited.connect(_clear_editor_debugger)

	if editor_debugger != null:
		# get selected item
		#"_tree_view" in editor_debugger and
		if editor_debugger._tree_view == null:
			# just ignore?
			# TODO what if its not from warning update
			return 
		# todo this isn't updated...
		var node_view = editor_debugger._tree_view.get_selected()
		base_instance_node = editor_debugger._get_node_from_view(node_view)

	# todo handle multiple ?
	var selection = EditorInterface.get_selection().get_selected_nodes()[0] if !EditorInterface.get_selection().get_selected_nodes().is_empty() else null
	
	cmd_inputs = [EditorInterface, selection, ClassDB, dynamic_cmd_items.duplicate(), cmd_hist, self]
	base_cmd_input_names = ["EditorInterface", "sel", "ClassDB", "allvars", "cmd_hist", "cmd_runner"]
	cmd_input_names = base_cmd_input_names.duplicate()
	
	for dynamic_cmd_item_name in dynamic_cmd_items:
		if not dynamic_cmd_item_name is String:
			_outputerr("invalid dynamic cmd item ", dynamic_cmd_item_name)
			continue
		cmd_input_names.push_back(dynamic_cmd_item_name)
		cmd_inputs.push_back(dynamic_cmd_items[dynamic_cmd_item_name])


func _run_expression(cmd_text: String) -> bool:
	#if not base_instance_node:
		## Not needed, no selection is fine
		#_outputerr("No node selected. cmd: `%s`" % [cmd_text])
		#return false

	var expr := Expression.new()
	var err := expr.parse(cmd_text, cmd_input_names)
	if err != OK:
		_outputerr("Parse error. cmd: `%s` error:%s %s" % [cmd_text, err,expr.get_error_text()])
		return false
	if verbose_mode: _output("Running cmd: `%s` on node `%s` (%s)" % [cmd_text, base_instance_node.name if base_instance_node else "none", base_instance_node.get_class() if base_instance_node else "none"], true)
	var result = expr.execute(cmd_inputs, base_instance_node, true, false)
	if expr.has_execute_failed():
		_outputerr("Exec failed: %s" % expr.get_error_text())
		return false

	if verbose_mode: _output("cmd Result: `%s`" % [result], true)
	else: _output("cmd %s `%s` = `%s`" % [base_instance_node.name if base_instance_node else "", cmd_text, result])
	last_result = result
	return true

func _run_cmd(cmd_text: String) -> bool:
	#if await _run_func(cmd_text):
		#return true
	var processed := _preprocess_cmd(cmd_text)
	cmd_text = processed[0]
	var await_result : bool = processed[1]
	if cmd_text.is_empty():
		return true
	var worked := _run_expression(cmd_text)
	if worked and await_result:
		await last_result
	return worked

func _run_cmds() -> void:
	var cmd_txt := cmd_input.text
	if cmd_txt.strip_edges().is_empty():
		_outputerr("No cmd to execute!")
		return

	# save cmd history
	if cmd_hist.is_empty() or cmd_hist[cmd_hist.size() - 1] != cmd_txt:
		#cmd_hist = cmd_hist.filter(func (a): return cmd_hist.count(a) == 1)
		for i in max(0, cmd_hist.size() - max_hist_size):
			cmd_hist.pop_front()
		cmd_hist.push_back(cmd_txt)
		cmd_hist_index = cmd_hist.size() - 1
		# clear if different type? idk
		# dont save if already the same as other previous commands? move old commands instead of re-adding?
	
	_update_inputs()
	#verbose_mode = true

	var cmds := cmd_txt.strip_edges().replace(";","\n").split("\n", false)
	
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

func _check_expression(cmd_text: String, check_exec: Array) -> String:
	var processed := _preprocess_cmd(cmd_text)
	cmd_text = processed[0]
	#var await_result : bool = processed[1]
	var const_portion : String = processed[2]

	if cmd_text.is_empty():
		#print("empty")
		check_exec[0] = false
		return "[color=yellow]No command[/color]"

	if const_portion.is_empty():
		check_exec[0] = false
		#return ""
		return "[color=gray][i]Non-const, skipping exec checks[/i][/color]"
	
	var expr := Expression.new()
	var err := expr.parse(const_portion, cmd_input_names)
	if err != OK:
		check_exec[0] = false
		return "[color=red]Parse Error:[/color] %s; %s `%s`" % [error_string(err), expr.get_error_text(), const_portion]
	
	if not check_exec[0]:
		# warning was already printed
		return ""

	# NOTE gdscript doesn't have const calls so this can change things...
	var result = expr.execute(cmd_inputs, base_instance_node, false, true)
	if expr.has_execute_failed():
		check_exec[0] = false
		# TODO ignore const call errors. cannot check cause error message sucks rn https://github.com/godotengine/godot/pull/114216
		# "Method not const in const instance"
		return "[color=red]Error:[/color] %s" % expr.get_error_text()
	#return ""
	return "[color=darkgreen]%s[/color]" % cmd_text

func _update_warning_label() -> void:
	var cmd_txt := cmd_input.text
	_update_inputs()
	var cmds := cmd_txt.strip_edges().replace(";","\n").split("\n", false)
	
	var warnings := []

	#print("running commands")
	var check_ref := [true]
	for cmd in cmds:
		cmd = cmd.strip_edges()
		if cmd.is_empty():
			continue
		warnings.push_back(_check_expression(cmd, check_ref))
	
	if cmds.is_empty():
		warning_label.hide()
		return
	
	warning_label.show()
	
	var warning_text = "\n".join(warnings)
	if warning_text.is_empty():
		warning_label.text = "[color=green]Valid[/color]"
		return
	
	var base_text = ("base: %s(%s)\n" % [base_instance_node.name, base_instance_node.get_class()]) if base_instance_node else ""
	#warning_label.text = "[color=red]"+warnings+"[/color]"
	warning_label.text = "%s%s" % [base_text, warning_text]
	


func _open_in_new_inspector(obj : Object) -> void:
	if obj == null:
		return

	var holder := EditorInterface.get_base_control()

	#EditorInterface.inspect_object(last_result, "", true)
	var inspector_window := Window.new()
	var obj_name : String = obj.name if "name" in obj else str(obj)
	inspector_window.title = "'%s' (%s) Inspector" % [obj_name, obj.get_class()]
	inspector_window.name = "Custom Inspector for '%s'" % obj_name
	inspector_window.wrap_controls = true
	
	var bg_panel := Panel.new()
	bg_panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg_panel.add_theme_stylebox_override("panel", get_theme_stylebox("PanelForeground", "EditorStyles"))
	inspector_window.add_child(bg_panel)
	
	var outer_margin := MarginContainer.new()
	outer_margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var margin_value = 6
	outer_margin.add_theme_constant_override("margin_top", margin_value)
	outer_margin.add_theme_constant_override("margin_left", margin_value)
	outer_margin.add_theme_constant_override("margin_bottom", margin_value)
	outer_margin.add_theme_constant_override("margin_right", margin_value)

	inspector_window.add_child(outer_margin)
	
	var box := VBoxContainer.new()
	outer_margin.add_child(box)
	
	var label_box := HBoxContainer.new()
	label_box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(label_box)
	var icon_texture := get_theme_icon(obj.get_class(), "EditorIcons")
	var _no_texture := get_theme_icon("", "EditorIcons")
	if (icon_texture == null or icon_texture == _no_texture):
		icon_texture = get_theme_icon("Node", "EditorIcons")
	var icon_texture_rect := TextureRect.new()
	icon_texture_rect.texture = icon_texture
	icon_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	label_box.add_child(icon_texture_rect)
	
	var name_label := Label.new() 
	name_label.text = obj_name + ": " + obj.get_class()
	label_box.add_child(name_label)
	
	#var close_btn := Button.new()
	#close_btn.text = "X"
	#close_btn.flat = true
	#var spacer1 := label_box.add_spacer(false)
	#spacer1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	#label_box.add_child(close_btn)
	
	# filter
	var filter_box := HBoxContainer.new()
	
	var search_line_edit := LineEdit.new()
	search_line_edit.placeholder_text = "Filter Properties"
	search_line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_line_edit.right_icon = get_theme_icon("Search", "EditorIcons")
	search_line_edit.set_clear_button_enabled(true)
	filter_box.add_child(search_line_edit)
	
	var settings_btn := MenuButton.new()
	settings_btn.icon = get_theme_icon("Tools", "EditorIcons")
	filter_box.add_child(settings_btn)
	
	box.add_child(filter_box)
	
	var inspector_margin := MarginContainer.new()
	inspector_margin.theme_type_variation = &"NoBorderHorizontalBottom"
	inspector_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(inspector_margin)
	

	var new_inspector : EditorInspector = EditorInspector.new()
	#var new_inspector := EditorInspector.new()
	if new_inspector.has_method("create_default_inspector"):
		# added in 4.7.beta1
		new_inspector = Callable(EditorInspector, "create_default_inspector").call(search_line_edit)
		#new_inspector.call("create_default_inspector", search_line_edit)
	#var copy_inspector := EditorInterface.get_inspector().duplicate()
	#var new_inspector = copy_inspector
	new_inspector.scroll_hint_mode = ScrollContainer.SCROLL_HINT_MODE_ALL
	new_inspector.custom_minimum_size = Vector2(100, 100)
	inspector_margin.add_child(new_inspector)
	
	holder.add_child(inspector_window)
	inspector_window.popup_centered(Vector2(500,500))
	new_inspector.edit(obj)
	
	settings_btn.get_popup().add_item("Expand All")
	settings_btn.get_popup().add_item("Collapse All")
	settings_btn.get_popup().add_item("Expand All non-default")
	var _on_settings_btn := func(idx):
		pass
		if not new_inspector.has_method("expand_all_folding"):
			print("Cannot expand/collapse!")
			return
		match idx:
			0:
				new_inspector.expand_all_folding()
			1:
				new_inspector.collapse_all_folding()
			2:
				new_inspector.expand_revertable()
	settings_btn.get_popup().id_pressed.connect(_on_settings_btn)
	
	var _set_name := func(_obj_name, _obj):
		inspector_window.title = "'%s' (%s) Inspector" % [_obj_name, _obj.get_class()]
		inspector_window.name = "Custom Inspector for '%s'" % _obj_name
		name_label.text = _obj_name + ": " + _obj.get_class()

	var _close_inspector := func(): 
		inspector_window.queue_free()
		if obj is Node:
			obj.renamed.disconnect(_set_name)
	inspector_window.close_requested.connect(_close_inspector)
	#close_btn.pressed.connect(_close_inspector)
	if obj is Node:
		obj.renamed.connect(_set_name.bind(obj))


func _on_cmd_run_button_pressed() -> void:
	_run_cmds()

func _load_hist():
	var savecfg := ConfigFile.new()
	var err := savecfg.load(save_path)
	if err!=OK:
		printerr("cmd runner failed to load cfg! ", error_string(err))
		return
	var hist = savecfg.get_value("cmds", "cmd_hist")
	cmd_hist = hist
	cmd_hist_index = -1
	#text = hist

func _save_hist():
	var savecfg := ConfigFile.new()
	var err := savecfg.load(save_path)
	if err!=OK:
		#print("failed to load cfg!",err)
		# make new one?
		#printerr("cmd runner failed to open cfg file!")
		print("cmd runner making new cfg file")
		#savecfg.
		#return
	#var prev_hist = savecfg.get_value("cmds", "cmd")
	savecfg.set_value("cmds", "cmd_hist", cmd_hist)
	savecfg.save(save_path)


func _on_text_changed() -> void:
	if is_part_of_edited_scene():
		return
	_update_run_button_vis()
	_update_warning_label()

func _update_run_button_vis() -> void:
	cmd_run_button.visible = not cmd_input.text.strip_edges().is_empty()

	#if not cmd_hist.is_empty():
		#cmd_hist_index = cmd_hist.size() - 1
	
	# Control s x "plugin.gd"
	#if cmd_run_button.visible:
		#var savecfg := ConfigFile.new()
		#savecfg.set_value("cmd_hist", "cmd", text.strip_edges())
		#savecfg.save(save_path)

func _on_gui_input(event: InputEvent) -> void:
	if is_part_of_edited_scene():
		return
	var kev := event as InputEventKey
	if kev and not kev.is_echo() and kev.pressed:
		if kev.keycode == KEY_ENTER and not kev.is_command_or_control_pressed():
			_run_cmds()
			accept_event()
		# todo cannot use normal key up...
		var c_line := cmd_input.get_caret_line()
		var c_col := cmd_input.get_caret_column()
		var line_count := cmd_input.get_line_count()
		var at_top := line_count == 0 or (c_line == 0 and c_col == 0)
		var at_bottom := line_count == 0 or (c_line == line_count - 1 and cmd_input.get_line_wrap_index_at_column(c_line, c_col) == cmd_input.get_line_wrap_count(c_line))
		if kev.keycode == KEY_UP and at_top:
			if cmd_hist_index == 0:
				return
			#print("up ", cmd_hist_index, text, " ", cmd_hist[cmd_hist_index])
			if cmd_hist_index < 0:
				cmd_hist_index = cmd_hist.size() - 1
			if cmd_input.text == cmd_hist[cmd_hist_index]:
				cmd_hist_index -= 1
			assert(cmd_hist_index < cmd_hist.size() and cmd_hist_index >= 0)
			cmd_input.text = cmd_hist[cmd_hist_index]
			accept_event()
		if kev.keycode == KEY_DOWN and at_bottom:
			if cmd_hist_index >= cmd_hist.size() - 1:
				# todo store wip text?
				cmd_input.text = ""
				return
			cmd_hist_index += 1
			assert(cmd_hist_index < cmd_hist.size() and cmd_hist_index >= 0)
			cmd_input.text = cmd_hist[cmd_hist_index]
			accept_event()


func _on_symbol_hovered(symbol: String, line: int, column: int) -> void:
	pass # Replace with function body.
	# todo possible?
	#tooltip

func _complete_request():
	pass
	#var ctext = cmd_input.get_text_for_code_completion()
	# Expression has no built in completion, so it would be a pain
	# gdscripts one isnt exposed either...
	
	#var gdscript_lang : ScriptLanguage
	#gdscript_lang.
	#update_code_completion_options(true)
	#GDScriptLanguageProtocol
	# todo the code complete popup would be in the way anyway since its not a popup
