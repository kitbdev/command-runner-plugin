extends RefCounted
class_name CommandRunnerCustomCommands

var cmd_runner: CommandRunner

## All functions that start with `_cmd_` can be run by typing the rest of the function name. No parenthesis 
## These may take parameters, comma separated
## `_cmdc_` are constant and will be executed before submitting

## test
# func _cmd_test():
# 	print("test method")

# func _cmdc_testc():
# 	print("testc method")

const BUILTIN_TYPES: Array = ["NIL", "bool", "int", "float", "String", "Vector2", "Vector2I", "Rect2", "Rect2I", "Vector3", "Vector3I", "Transform2D", "Vector4", "Vector4I", "Plane", "Quaternion", "Aabb", "Basis", "Transform3D", "Projection", "Color", "StringName", "NodePath", "Rid", "Object", "Callable", "Signal", "Dictionary", "Array", "PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedColorArray", "PackedVector4Array", "MAX", ]

## Output list of commands and variables.
func _cmdc_help() -> bool:
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
		var names := (method.args as Array).map(func(val: Variant) -> String:
			var type := ""
			if val.type != 0:
				type = ":%s" % BUILTIN_TYPES[val.type]
			return val.name + type
		)
		if not names.is_empty():
			cmd_name += "(" + ",".join(names) + ")"
		
		# Get descriptions by parsing the file for doc comments
		var source := (get_script() as Script).source_code
		var method_at := source.find(mname)
		if method_at >= 0:
			var doc_start_at := method_at - 7 # `\nfunc ` -1
			while doc_start_at >= 0:
				var prev_line := source.rfind("\n", doc_start_at)
				#if mname.ends_with("test"): print("'"+source.substr(prev_line+1, doc_start_at-prev_line)+"'")
				if prev_line >= 0 and source.substr(prev_line + 1, doc_start_at - prev_line).strip_edges().begins_with("##"):
					doc_start_at = prev_line - 1
				else:
					break
			if doc_start_at != method_at - 7:
				var docs := source.substr(doc_start_at, method_at - doc_start_at - 6).replace("\n", " ").remove_chars("#").strip_edges()
				cmd_name += " [color=cyan][i]%s[/i][/color]" % docs

		cmds.push_back(cmd_name)

	cmd_runner.output("help\ncmds:\n%s\ninputs: %s\nvars: %s" % ["\n".join(cmds), cmd_runner._cmd_input_names, cmd_runner.get_all_vars()], true)
	return true


## Toggle verbose output mode
func _cmd_q() -> bool:
	cmd_runner.verbose_mode = not cmd_runner.verbose_mode
	cmd_runner.output("verbose mode %s" % cmd_runner.verbose_mode, true)
	return true

## Toggle toast output
func _cmd_toast() -> bool:
	cmd_runner.toast_output = not cmd_runner.toast_output
	cmd_runner.output("cmd_runner.toast_output %s" % cmd_runner.toast_output, true)
	return true

## Clear history
func _cmd_cls() -> bool:
	# Defer to not add this command to the history
	cmd_runner.clear_history.call_deferred()
	return true

## Open Editor Help documentation for the class of the given object.
func _cmd_docs(target: Object = null) -> bool:
	if target == null:
		cmd_runner.outputerr("No target to open docs!")
		return false
	EditorInterface.get_script_editor().goto_help("class_name:%s" % target.get_class())
	return true

## create a new instance of a class. Useful if you need access to something from the editor, like JSON 
func _cmd_new(var_name: String, opt_class_name := "") -> bool:
	# todo can be automatic?
	var new_class_name := var_name
	if opt_class_name != "":
		new_class_name = opt_class_name

	var made_new := true
	var new_class: Variant = null
	if Engine.has_singleton(new_class_name):
		new_class = Engine.get_singleton(new_class_name)
		made_new = false
	elif ClassDB.can_instantiate(new_class_name):
			# make var instead
		new_class = ClassDB.instantiate(new_class_name);
	#elif ClassDB.class_exists(new_class_name):
		#new_class = ClassDB.class_call_static()
	if new_class == null:
		cmd_runner.outputerr("Cannot make class %s" % new_class_name)
		return false

	var worked := cmd_runner.add_var(var_name, new_class)
	if not worked:
		return false
	if made_new:
		cmd_runner.output("made new class %s %s" % [var_name, new_class_name])
	else:
		cmd_runner.output("got class %s %s" % [var_name, new_class_name])
	return true

## Create a new variable for later use `var name,value`
func _cmd_var(var_name: String, value: Variant) -> bool:
	var prefix_action := "Updated" if cmd_runner.has_var(var_name) else "Saved"
	if cmd_runner.add_var(var_name, value):
		cmd_runner.output("%s var `%s` to value `%s`" % [prefix_action, var_name, value], true)
	return true

## Remove a variable. Use `allvars` to erase all.
func _cmd_erase(var_name: String) -> bool:
	if var_name == "allvars":
		# erase all
		cmd_runner.remove_all_vars()
		cmd_runner.output("Erased allvars")
		return true
	var prev_dyn_value: Variant = cmd_runner.get_var_value(var_name)
	cmd_runner.remove_var(var_name)
	cmd_runner.output("Erased var `%s`, previously %s" % [var_name, prev_dyn_value])
	return true

class SignalTracker extends RefCounted:
	var vname := ""
	var name := "unknown signal"
	var obj_name := "unknown obj"
	var cmd_runner: CommandRunner = null
	
	func report(...args: Array) -> void:
		var s := "%s: Signal `%s` emitted on `%s` with args `%s`" % [vname, name, obj_name, args]
		#if cmd_runner != null:
			## should this use output func? it can happen any time
			#cmd_runner.cmd_runner.output(s)
		#else:
			#print(s)
		print(s)

func _get_obj_name(target_obj: Object) -> String:
	if not target_obj:
		return "null"

	var targ_name := ""
	if target_obj is Node:
		var targ_node := target_obj as Node
		targ_name = targ_node.name
	elif target_obj is Resource:
		var targ_res := target_obj as Resource
		targ_name = "%s-%s" % [targ_res.get_class(), targ_res.get_rid()]
	else:
		#targ_name = "%s-r%s" % [target_obj.get_class(), randi() % 10000]
		targ_name = "%s-%s" % [target_obj.get_class(), str(target_obj)]

	return targ_name

## Track a signal on an object. Prints a message when the signal fires.
func _cmd_track(signame: String, target_obj: Object = null) -> bool:
	if target_obj == null:
		target_obj = cmd_runner._base_instance_node

	var targ_name := _get_obj_name(target_obj)
	if target_obj == null or not target_obj.has_signal(signame):
		cmd_runner.outputerr("Cannot track signal `%s` on object `%s`: not found" % [signame, targ_name])
		return true

	# get the selected signal from the Signal dock somehow?
	#var siglist := target_obj.get_signal_list()
	#for sig in siglist:
		#if sig["name"] != signame:
			#return
		#for arg in sig["args"]:

	var vname := "track_%s_%s" % [signame, targ_name]
	var sig_tracker := SignalTracker.new()
	sig_tracker.vname = vname
	sig_tracker.name = signame
	sig_tracker.obj_name = targ_name
	sig_tracker.cmd_runner = cmd_runner
	target_obj.connect(signame, sig_tracker.report)

	if cmd_runner.add_var(vname, sig_tracker):
		cmd_runner.output("Tracking signal `%s` on `%s`" % [vname, targ_name])
	return true

## Stop tracking a signal on an object, or stop tracking all.
func _cmd_trackclear(signame: String, target_obj: Object = null) -> bool:
	if signame != "":
		if target_obj == null:
			target_obj = cmd_runner._base_instance_node

		var targ_name := _get_obj_name(target_obj)
		if target_obj == null or not target_obj.has_signal(signame):
			cmd_runner.outputerr("Cannot trackclear signal `%s` on object `%s`: not found" % [signame, targ_name])
			return true

		var vname := "track_%s_%s" % [signame, targ_name]
		if not cmd_runner.has_var(vname):
			cmd_runner.outputerr("Cannot trackclear signal `%s`: not found" % [vname])
			return true
		cmd_runner.remove_var(vname)
		cmd_runner.output("Removed signal tracking for signal `%s`" % signame)
		return true

	var to_rem := []
	var all_vars := cmd_runner.get_all_vars()
	for dci_name: Variant in all_vars:
		var val: Variant = all_vars[dci_name]
		if val is SignalTracker:
			to_rem.push_back(val)
	for v: Variant in to_rem:
		all_vars.erase(v)
	cmd_runner._update_inputs()
	cmd_runner.output("Cleared all signal tracking")
	return true

## Use EditorDebugger to focus on a node
func _cmd_focus_on(target: Node = null) -> bool:
	if target == null or cmd_runner.editor_debugger == null:
		cmd_runner.output("No target or no EditorDebugger")
		return false
	if cmd_runner.editor_debugger.has_method("_focus_in_tree"):
		@warning_ignore("unsafe_method_access")
		cmd_runner.editor_debugger._focus_in_tree(target)
	else:
		cmd_runner.outputerr("Cannot focus on target, EditorDebugger api")
	return true


## Open a new floating inspector
func _cmd_inspect(target: Object = null) -> bool:
	#if last_result !=null and last_result is Object:
		#target = last_result
	#if target == null:
		#_run_expression("self")
		#if last_result is Object:
			#target = last_result
	if target == null:
		cmd_runner.outputerr("No target Object to inspect!")
		return false
	cmd_runner.output("Inspecting %s" % target)
	_open_in_new_inspector(target)
	return true

func _open_in_new_inspector(obj: Object) -> void:
	if obj == null:
		return

	#EditorInterface.inspect_object(_last_result, "", true)

	var holder := EditorInterface.get_base_control()

	# Make new inspector
	var inspector_window := Window.new()

	var obj_name: String = _get_obj_name(obj)
	inspector_window.title = "'%s' (%s) Inspector" % [obj_name, obj.get_class()]
	inspector_window.name = "Custom Inspector for '%s'" % obj_name
	inspector_window.wrap_controls = true
	
	var bg_panel := Panel.new()
	bg_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_panel.add_theme_stylebox_override("panel", holder.get_theme_stylebox("PanelForeground", "EditorStyles"))
	inspector_window.add_child(bg_panel)
	
	var outer_margin := MarginContainer.new()
	outer_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin_value := 6
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
	var icon_texture := holder.get_theme_icon(obj.get_class(), "EditorIcons")
	var _no_texture := holder.get_theme_icon("", "EditorIcons")
	if (icon_texture == null or icon_texture == _no_texture):
		icon_texture = holder.get_theme_icon("Node", "EditorIcons")
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
	search_line_edit.right_icon = holder.get_theme_icon("Search", "EditorIcons")
	search_line_edit.set_clear_button_enabled(true)
	filter_box.add_child(search_line_edit)
	
	var settings_btn := MenuButton.new()
	settings_btn.icon = holder.get_theme_icon("Tools", "EditorIcons")
	filter_box.add_child(settings_btn)
	
	box.add_child(filter_box)
	
	var inspector_margin := MarginContainer.new()
	inspector_margin.theme_type_variation = &"NoBorderHorizontalBottom"
	inspector_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(inspector_margin)
	

	var new_inspector: EditorInspector = EditorInspector.new()
	if new_inspector.has_method("create_default_inspector"):
		# added in 4.7.beta1
		new_inspector = Callable(EditorInspector, "create_default_inspector").call(search_line_edit)

	new_inspector.scroll_hint_mode = ScrollContainer.SCROLL_HINT_MODE_ALL
	new_inspector.custom_minimum_size = Vector2(100, 100)
	inspector_margin.add_child(new_inspector)
	
	holder.add_child(inspector_window)
	inspector_window.popup_centered(Vector2(500, 500))
	new_inspector.edit(obj)
	
	settings_btn.get_popup().add_item("Expand All")
	settings_btn.get_popup().add_item("Collapse All")
	settings_btn.get_popup().add_item("Expand All non-default")

	var _on_settings_btn := func(idx: int) -> void:
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
	
	var _set_name := func(_obj_name: String, _obj: Object) -> void:
		inspector_window.title = "'%s' (%s) Inspector" % [_obj_name, _obj.get_class()]
		inspector_window.name = "Custom Inspector for '%s'" % _obj_name
		name_label.text = _obj_name + ": " + _obj.get_class()

	var _close_inspector := func() -> void:
		inspector_window.queue_free()
		if obj is Node:
			(obj as Node).renamed.disconnect(_set_name)
	inspector_window.close_requested.connect(_close_inspector)
	#close_btn.pressed.connect(_close_inspector)
	if obj is Node:
		(obj as Node).renamed.connect(_set_name.bind(obj))

## Reload plugin
func _cmd_reload(plugin_name := "") -> bool:
	if plugin_name.is_empty():
		# "commandrunner"
		plugin_name = (get_script() as Script).resource_path.get_base_dir() + "/plugin.cfg"

	var reload_func := func() -> void:
		var tree := EditorInterface.get_base_control().get_tree()
		await tree.process_frame
		if EditorInterface.is_plugin_enabled(plugin_name):
			EditorInterface.set_plugin_enabled(plugin_name, false)
			await tree.process_frame
		print("Reloading plugin `%s`" % plugin_name)
		EditorInterface.set_plugin_enabled(plugin_name, true)

	reload_func.call()

	return true
