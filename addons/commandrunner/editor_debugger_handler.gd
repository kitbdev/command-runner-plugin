@tool
extends EditorDebuggerPlugin
class_name CmdRunnerEditorDebuggerHandler

static var _singleton : CmdRunnerEditorDebuggerHandler = null

static func get_singleton() -> CmdRunnerEditorDebuggerHandler:
	if _singleton == null:
		_singleton = CmdRunnerEditorDebuggerHandler.new()
	return _singleton

const message_prefix := "command_runner"

var cmd_runner : CommandRunner

var is_setup := false
signal response_received
var response_data : Array

const executor_scene_uid = "uid://cxtsngk24p1kf"
#const executor_scene_path = "res://addons/commandrunner/cmd_runner_remote_executor.tscn"

func _has_capture(capture: String) -> bool:
	return capture == message_prefix

func _capture(message: String, data: Array, session_id: int) -> bool:
	print("CmdRunner handler got message %s %s session %s" % [message, data, session_id])
	message = message.trim_prefix(message_prefix+":")
	if message == "output":
		if data.size() != 2:
			printerr("Command Runner capture invalid data size")
		cmd_runner.output(data[0] as String, data[1] as bool)
		return true
	if message == "outputerr":
		if data.size() != 1:
			printerr("Command Runner capture invalid data size")
		cmd_runner.outputerr(data[0] as String)
		return true
	if message == "cmd_finished":
		response_data = data
		response_received.emit()
		return true
	return false

func _setup() -> void:
	is_setup = true
	#todo multi session?
	var session := get_session(0)
	session.stopped.connect(_session_ended)

	# inject node
	var instantiate_node_msg := "scene:live_instantiate_node"
	var data := [
		# parent path
		".",
		# packed scene resource path
		executor_scene_uid,
		#executor_scene_path,
		# node name
		"CmdRunnerDebuggerExecutor"
	]
	print("setup ", instantiate_node_msg, data)
	session.send_message(instantiate_node_msg, data)
	
	# todo need to wait?
	#await EditorInterface.get_base_control().get_tree().process_frame
	# no way to verify?
	#_send_message_to_all("setup")

func _session_ended() -> void:
	is_setup = false

func is_active() -> bool:
	return get_session(0).is_active()

func _send_message_to(message: String, data: Array = [], session_id: int = 0) -> bool:
	var sent := false
	var sessions : Array
	if session_id == -1:
		sessions = get_sessions()
	else:
		sessions = [ get_session(session_id) ]
	print("sending '%s' to %s sessions" % [message, sessions.size()])

	for session : EditorDebuggerSession in sessions:
		if not session.is_active():
			continue
		#print("sending to ", session)
		session.send_message(message_prefix+":"+message, data)
		sent = true
	return sent


func send_message(message: String, data: Array = [], session_id: int = 0) -> void:
	if not is_setup:
		_setup()
	
	var sent := _send_message_to(message, data, session_id)
	if not sent:
		response_data = [ERR_CANT_CONNECT]
		return


func send_message_and_wait(message: String, data: Array = [], session_id: int = 0, timeout := 3.0) -> void:
	var send_tween : Tween = EditorInterface.get_base_control().get_tree().create_tween()
	send_tween.tween_await(response_received).set_timeout(timeout)
	send_tween.parallel().tween_callback(send_message.bind(message, data, session_id))
	#send_tween.tween_callback(print.bind("sent msg")) # todo this waits for both?
	response_data = [ERR_TIMEOUT]
	send_tween.play.call_deferred()
	await send_tween.finished
