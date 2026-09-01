extends Node
class_name FileUtiles

# The target Windows registry key for per-app GPU scaling
const WIN_GPU_REGISTRY_PATH = "HKCU\\Software\\Microsoft\\DirectX\\UserGpuPreferences"




# --- JSON Data Handling ---

# Loads and parses a JSON file, returning a default value if it fails or doesn't exist
static func load_json(filepath: String, default_value: Variant) -> Variant:
	if not FileAccess.file_exists(filepath):
		return default_value
		
	var file := FileAccess.open(filepath, FileAccess.READ)
	var json_string := file.get_as_text()
	var json := JSON.new()
	
	if json.parse(json_string) == OK:
		return json.data
	return default_value

# Serializes and saves data to a JSON file with tab indentation for readability
static func save_json(filepath: String, data: Variant) -> void:
	var file := FileAccess.open(filepath, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t"))




# --- Configuration File Management ---

# Reads a specific key from a simple key=value config file
static func read_config_value(filepath: String, key: String, default_value: String = "") -> String:
	if not FileAccess.file_exists(filepath):
		return default_value
		
	var file := FileAccess.open(filepath, FileAccess.READ)
	
	# Scan line-by-line to avoid loading massive files into memory
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.begins_with(key + "="):
			return line.trim_prefix(key + "=")
			
	return default_value

# Updates a specific key in a config file while preserving all other lines and comments
static func write_config_value(filepath: String, key: String, value: String) -> void:
	var lines := PackedStringArray()
	var found := false
	
	if FileAccess.file_exists(filepath):
		var file := FileAccess.open(filepath, FileAccess.READ)
		
		while not file.eof_reached():
			var line := file.get_line()
			
			# Overwrite the target key when found
			if line.strip_edges().begins_with(key + "="):
				lines.append(key + "=" + value)
				found = true
			# Retain all other non-empty lines to preserve user comments
			elif not (file.eof_reached() and line.is_empty()):
				lines.append(line)
				
	# Append the key to the end if it didn't already exist
	if not found:
		lines.append(key + "=" + value)
		
	# Write the buffered array back to the file
	var write_file := FileAccess.open(filepath, FileAccess.WRITE)
	for line in lines:
		write_file.store_line(line)




# --- File System Operations ---

# Deletes a directory and all of its contents (files and subfolders)
static func remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
		
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		# Skip the current (.) and parent (..) directory pointers
		if file_name != "." and file_name != "..":
			var full_path = path.path_join(file_name)
			
			# Recursively dig into subfolders, otherwise delete the file
			if dir.current_is_dir():
				remove_dir_recursive(full_path)
			else:
				DirAccess.remove_absolute(full_path)
				
		file_name = dir.get_next()
		
	dir.list_dir_end()
	DirAccess.remove_absolute(path)

# Copies a file or folder and all its contents to a new destination
static func copy_recursive(src: String, dst: String) -> void:
	if FileAccess.file_exists(src):
		# Target is a single file: ensure the destination folder exists, then copy
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		DirAccess.copy_absolute(src, dst)
		
	elif DirAccess.dir_exists_absolute(src):
		# Target is a folder: create the destination folder, then copy contents
		DirAccess.make_dir_recursive_absolute(dst)
		var dir := DirAccess.open(src)
		
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			
			while file_name != "":
				if file_name != "." and file_name != "..":
					copy_recursive(src.path_join(file_name), dst.path_join(file_name))
				file_name = dir.get_next()
				
			dir.list_dir_end()



static func validate_iso_directory(base_dir: String) -> Dictionary:
	var iso_dir = base_dir.path_join(AppConfig.ISOS_DIR)
	
	if not DirAccess.dir_exists_absolute(iso_dir):
		return {"valid": false, "message": "The 'isos' folder is missing."}
		
	var dir = DirAccess.open(iso_dir)
	if not dir:
		return {"valid": false, "message": "Could not access the 'isos' folder."}
		
	var iso_count = 0
	var bin_count = 0
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var ext = file_name.get_extension().to_lower()
			if ext == "iso":
				iso_count += 1
			elif ext == "bin":
				bin_count += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if iso_count == 4 and bin_count == 0:
		return {"valid": true, "message": "Ready to launch."}
	elif bin_count == 4 and iso_count == 0:
		return {"valid": true, "message": "Ready to launch."}
	else:
		return {
			"valid": false,
			"message": "Found %d ISO(s) and %d BIN(s). Please provide exactly 4 of the same format." % [iso_count, bin_count]
		}



# --- External Integrations ---


# Reads the current GPU preference directly from the host operating system
# Returns: 1 (Discrete), 2 (Integrated), or 0 (Auto/None)
static func get_system_gpu_preference(base_dir: String) -> int:
	if OS.has_feature("windows"):
		var java_path = base_dir.path_join("jdk25/bin/java.exe")
		if not FileAccess.file_exists(java_path):
			java_path = base_dir.path_join("jdk25/bin/javaw.exe")
			
		var win_java_path = ProjectSettings.globalize_path(java_path).replace("/", "\\")
		var output = []
		
		# 'reg query' prints the registry key data, which we capture in 'output'
		var exit_code = OS.execute("reg", ["query", WIN_GPU_REGISTRY_PATH, "/v", win_java_path], output, true)
		
		# exit_code 0 means the key exists and was successfully read
		if exit_code == 0 and output.size() > 0:
			var result_string = output[0]
			if "GpuPreference=2;" in result_string:
				return 1 # Discrete
			elif "GpuPreference=1;" in result_string:
				return 2 # Integrated
				
		return 0 # Default to Auto if the key doesn't exist
		
	else:
		# Linux/Unix fallback reads the launch config
		var conf_path = base_dir.path_join("launch.conf")
		return read_config_value(conf_path, "GPU_PREFERENCE", "0").to_int()

# Maps the launcher's UI preference to the Windows DirectX GPU Shim
# Preference Index: 1 = Discrete, 2 = Integrated, 0 = Auto
static func apply_windows_gpu_registry(preference: int, base_dir: String) -> void:
	if not OS.has_feature("windows"):
		return
	
	var java_path = base_dir.path_join("jdk25/bin/java.exe")
	if not FileAccess.file_exists(java_path):
		java_path = base_dir.path_join("jdk25/bin/javaw.exe")
		
	# The Windows 'reg' command strictly requires backslashes
	var win_java_path = ProjectSettings.globalize_path(java_path).replace("/", "\\")
	var args = PackedStringArray()
	
	match preference:
		1:
			# GpuPreference=2 forces High Performance (Discrete GPU)
			args = ["add", WIN_GPU_REGISTRY_PATH, "/v", win_java_path, "/t", "REG_SZ", "/d", "GpuPreference=2;", "/f"]
		2:
			# GpuPreference=1 forces Power Saving (Integrated GPU)
			args = ["add", WIN_GPU_REGISTRY_PATH, "/v", win_java_path, "/t", "REG_SZ", "/d", "GpuPreference=1;", "/f"]
		0:
			# Deleting the key entirely lets Windows decide automatically
			args = ["delete", WIN_GPU_REGISTRY_PATH, "/v", win_java_path, "/f"]
			
	if not args.is_empty():
		# Execute silently in the background
		OS.execute("reg.exe", args)
