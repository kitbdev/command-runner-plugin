@tool
extends EditorDebuggerPlugin
class_name CmdRunnerEditorDebuggerHandler

static var _singleton: CmdRunnerEditorDebuggerHandler = null

static func get_singleton() -> CmdRunnerEditorDebuggerHandler:
	if _singleton == null:
		_singleton = CmdRunnerEditorDebuggerHandler.new()
	return _singleton

static func destruct() -> void:
	if _singleton:
		# refcounted, so it should free itself
		_singleton = null

const message_prefix := "command_runner"

var cmd_runner: CommandRunner

var is_setup := []

signal response_received
var response_data: Array

const executor_scene_uid = "uid://cxtsngk24p1kf"

func _has_capture(capture: String) -> bool:
	return capture == message_prefix

func _capture(message: String, data: Array, session_id: int) -> bool:
	if cmd_runner.verbose_mode:
		cmd_runner.output("CmdRunner handler got message %s %s session %s" % [message, data, session_id])
	message = message.trim_prefix(message_prefix + ":")
	if message == "output":
		if data.size() != 2:
			cmd_runner.outputerr("Command Runner capture invalid data size")
		var resp_output := "remote%s %s" % [session_id, data[0]]
		cmd_runner.output(resp_output, data[1] as bool)
		return true
	if message == "outputerr":
		if data.size() != 1:
			cmd_runner.outputerr("Command Runner capture invalid data size")
		var resp_output := "remote%s %s" % [session_id, data[0]]
		cmd_runner.outputerr(resp_output)
		return true
	if message == "cmd_finished":
		response_data = data
		response_received.emit()
		return true
	return false

func _setup(session_id: int) -> void:
	is_setup.push_back(session_id)

	var session := get_session(session_id)
	if not session.stopped.is_connected(_session_ended):
		session.stopped.connect(_session_ended.bind(session_id))

	# inject node
	var instantiate_node_msg := "scene:live_instantiate_node"
	
	var data := [
		# parent path (NodePath)
		^".",
		# packed scene resource path
		executor_scene_uid,
		#executor_scene_path,
		# node name
		"CmdRunnerDebuggerExecutor"
	]
	#print("setup ", instantiate_node_msg, data)
	session.send_message(instantiate_node_msg, data)
	
	# todo need to wait?
	#await EditorInterface.get_base_control().get_tree().process_frame
	# no way to verify?
	#_send_message_to_all("setup")

func _session_ended(session_id: int) -> void:
	#print("session %s ended" % session_id)
	is_setup.erase(session_id)

func is_active(session_id: int = 0) -> bool:
	return get_session(session_id).is_active()

func _send_message_to(message: String, data: Array = [], session_id: int = 0) -> bool:
	var sent := false
	var sessions: Array
	if session_id == -1:
		sessions = get_sessions()
	else:
		sessions = [get_session(session_id)]
	if cmd_runner.verbose_mode:
		cmd_runner.output("sending `%s` to session %s" % [message, session_id])

	for session: EditorDebuggerSession in sessions:
		if not session.is_active():
			continue
		#print("sending to ", session)
		session.send_message(message_prefix + ":" + message, data)
		sent = true
	return sent


func send_message(message: String, data: Array = [], session_id: int = 0) -> void:
	#print("setup:", is_setup)
	if session_id not in is_setup:
		_setup(session_id)
	
	var sent := _send_message_to(message, data, session_id)
	if not sent:
		response_data = [ERR_CANT_CONNECT]
		return


func send_message_and_wait(message: String, data: Array = [], session_id: int = 0, timeout := 3.0) -> void:
	if not is_active(session_id):
		cmd_runner.outputerr("Cannot send remote cmd, session %s not active `%s` %s" % [session_id, message, data])
		response_data = [ERR_CONNECTION_ERROR]
		return
	var send_tween: Tween = EditorInterface.get_base_control().get_tree().create_tween()
	send_tween.tween_await(response_received).set_timeout(timeout)
	send_tween.parallel().tween_callback(send_message.bind(message, data, session_id))
	#send_tween.tween_callback(print.bind("sent msg")) # todo this waits for both?
	response_data = [ERR_TIMEOUT]
	send_tween.play.call_deferred()
	await send_tween.finished
