@tool
extends Object
class_name CmdRunnerUtil

static func nice_print_obj(obj: Object, with_class := true) -> String:
	if obj == null:
		return "null"
	if obj is Node:
		var objn := obj as Node
		if with_class:
			return "%s (%s)" % [objn.name, objn.get_class()]
		return objn.name
	return obj.to_string()
