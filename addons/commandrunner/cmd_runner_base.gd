@tool
@abstract
extends Node
class_name CommandRunnerBase

## Slightly more verbose messages.
@export var verbose_mode := false

var _cmd_inputs := []
var _cmd_input_names: PackedStringArray = []
var _base_cmd_input_names: PackedStringArray = []

var _dynamic_cmd_items := {}
var _auto_class_loads := []
var _created_vars := []

var _base_instance_node: Node = null
var _base_instance_override: Object = null

var _custom_commands: CommandRunnerCustomCommands = null

@abstract
func output(output_text: String, is_escaped: bool = false) -> void

@abstract
func outputerr(output_text: String) -> void

@abstract
func _update_inputs() -> void

func _update_var_inputs() -> void:
	for singleton: String in Engine.get_singleton_list():
		_cmd_input_names.push_back(singleton)
		_cmd_inputs.push_back(Engine.get_singleton(singleton))

	for dynamic_cmd_item_name: Variant in _dynamic_cmd_items:
		if not dynamic_cmd_item_name is String:
			outputerr("invalid dynamic cmd item %s" % dynamic_cmd_item_name)
			continue
		var cmd_name := dynamic_cmd_item_name as String
		_cmd_input_names.push_back(cmd_name)
		_cmd_inputs.push_back(_dynamic_cmd_items[cmd_name])

func get_base_instance() -> Object:
	if _base_instance_override == null:
		return _base_instance_node
	return _base_instance_override


func get_all_vars() -> Dictionary:
	return _dynamic_cmd_items

func has_var(var_name: String) -> bool:
	return _dynamic_cmd_items.has(var_name)

func get_var_value(var_name: String) -> Variant:
	return _dynamic_cmd_items[var_name]

## Add a new variable to access in Expressions.
## Use created=true to have the memory freed when done. 
func add_var(var_name: String, value: Variant, created := false) -> bool:
	if _base_cmd_input_names.has(var_name):
		outputerr("Invalid name `%s` overrides existing" % var_name)
		return false
	if created:
		_created_vars.push_back(var_name)
	_dynamic_cmd_items[var_name] = value
	_update_inputs()
	return true

func remove_var(var_name: String) -> bool:
	if not _dynamic_cmd_items.has(var_name):
		outputerr("Cannot erase var `%s`, does not exist" % var_name)
		return false
	if var_name in _created_vars:
		var obj := _dynamic_cmd_items[var_name] as Object
		if obj and obj is not RefCounted and (obj is not Node or (obj as Node).is_inside_tree()):
			obj.free()
	_dynamic_cmd_items.erase(var_name)
	_auto_class_loads.erase(var_name)
	_created_vars.erase(var_name)
	_update_inputs()
	return true

func remove_all_vars() -> bool:
	for var_name: String in _dynamic_cmd_items:
		if var_name in _created_vars:
			var obj := _dynamic_cmd_items[var_name] as Object
			if obj and obj is not RefCounted and (obj is not Node or (obj as Node).is_inside_tree()):
				obj.free()
	_dynamic_cmd_items.clear()
	_auto_class_loads.clear()
	_created_vars.clear()
	_update_inputs()
	return true

## Automatically create new classes from the given command.
func _auto_add_class(cmd_msg: String) -> bool:
	# This is so static methods can be called without needing to manually create a class.
	# Do not use ClassDB class list, it crashes.
	# Instead check each word from the command to see if it is a class.
	var cname := ""
	var potential_classes := []
	var in_word := false
	for i in cmd_msg.length():
		var c := cmd_msg[i]
		if is_symbol(c):
			in_word = false
			continue
		if not in_word:
			if i > 0 and not is_symbol(cmd_msg[i - 1]):
				continue
			in_word = true
			potential_classes.push_back("")
		potential_classes[-1] += c

	#print("found potentials: ", potential_classes)
	for cl: String in potential_classes:
		if not cl.is_empty() and ClassDB.class_exists(cl) and ClassDB.can_instantiate(cl):
			cname = cl
			break
	if cname.is_empty():
		return false
	if _auto_class_loads.has(cname) or has_var(cname):
		return false

	#print("found new ", cname)
	var new_instance: Object = ClassDB.instantiate(cname)
	if new_instance == null:
		printerr("Command Runner failed to create new instance of `%s`" % cname)

	# todo remove later if not needed somehow?
	_auto_class_loads.push_back(cname)
	add_var(cname, new_instance, true)

	return true

static func is_symbol(p_char: String) -> bool:
	return p_char != '_' && ((p_char >= '!' && p_char <= '/') || (p_char >= ':' && p_char <= '@') || (p_char >= '[' && p_char <= '`') || (p_char >= '{' && p_char <= '~') || p_char == '\t' || p_char == ' ')


#func get_matching_cmd(func_name: String, remote_only: bool) -> Dictionary

## get all commands
##[br] same as [method Object.get_method_list]() mostly
##[br] - name is the name of the method, as a String;
##[br] - args is an Array of dictionaries representing the arguments;
##[br] - default_args is the default arguments as an Array of variants;
##[br] - flags is a combination of [constant Object.MethodFlags];
##[br] - id is the method's internal identifier int;
##[br] - return is the returned value, as a Dictionary;
##[br] - cmd_name the actual cmd name
##[br] Note: The dictionaries of args and return are formatted identically to the results of [method Object.get_property_list](), although not all entries are used.
func get_all_cmds(remote_only: bool) -> Array[Dictionary]:
	var cmds: Array[Dictionary] = []
	for method in _custom_commands.get_method_list():
		var mname: String = method.name
		var min_length := 6 # _cmd_ and a name
		if mname.length() < min_length or not mname.begins_with("_cmd"):
			continue
		var flag_index := 4
		var flag := mname[flag_index]
		var is_func_const := false
		var is_editor_only := false
		var is_remote_only := false
		while flag != "_":
			if flag == "c":
				is_func_const = true
			if flag == "e":
				is_editor_only = true
			if flag == "r":
				is_remote_only = true
			flag_index += 1
			if flag_index >= mname.length():
				flag_index = -1
				break
			flag = mname[flag_index]

		if flag_index < 0:
			continue
		if is_editor_only and remote_only:
			continue
		if is_remote_only and not remote_only:
			continue

		var prefix_width := -flag_index - 1
		
		method["cmd_name"] = mname.right(prefix_width)
		method["const"] = is_func_const
		cmds.push_back(method)
	return cmds
