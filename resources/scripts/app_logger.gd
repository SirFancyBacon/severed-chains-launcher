class_name AppLogger

const LOG_FILE_NAME = "launcher.log"

# Internal helper to dynamically find the correct directory
static func _get_log_path() -> String:
	var base_dir = OS.get_executable_path().get_base_dir() if not OS.has_feature("editor") else ProjectSettings.globalize_path("res://")
	
	var data_dir = base_dir.path_join(AppConfig.MOD_DATA_DIR)
	if not DirAccess.dir_exists_absolute(data_dir):
		DirAccess.make_dir_recursive_absolute(data_dir)
		
	return data_dir.path_join(LOG_FILE_NAME)

# Core write function
static func _write_log(level: String, message: String) -> void:
	var log_path = _get_log_path()
	var file = FileAccess.open(log_path, FileAccess.READ_WRITE)
	
	if not file:
		file = FileAccess.open(log_path, FileAccess.WRITE)
	else:
		file.seek_end()
		
	if file:
		var timestamp = Time.get_datetime_string_from_system()
		var formatted_message = "[%s] [%s] %s" % [timestamp, level, message]
		file.store_line(formatted_message)
		file.close()
		
		# Echo to the Godot console for live debugging
		if level == "ERROR":
			printerr(formatted_message)
		else:
			print(formatted_message)

# --- Public API ---

static func error(message: String) -> void:
	_write_log("ERROR", message)

static func warning(message: String) -> void:
	_write_log("WARN", message)

static func info(message: String) -> void:
	_write_log("INFO", message)
