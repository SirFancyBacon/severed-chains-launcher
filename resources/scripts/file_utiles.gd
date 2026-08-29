extends Node
class_name FileUtiles

static func load_json(filepath: String, default_value: Variant) -> Variant:
	if not FileAccess.file_exists(filepath):
		return default_value
		
	var file := FileAccess.open(filepath, FileAccess.READ)
	var json_string := file.get_as_text()
	var json := JSON.new()
	
	if json.parse(json_string) == OK:
		return json.data
	return default_value

static func save_json(filepath: String, data: Variant) -> void:
	var file := FileAccess.open(filepath, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t"))


# --- Helper Functions ---

static func remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name != "." and file_name != "..":
				var full_path = path.path_join(file_name)
				if dir.current_is_dir():
					remove_dir_recursive(full_path)
				else:
					DirAccess.remove_absolute(full_path)
			file_name = dir.get_next()
		dir.list_dir_end()
		DirAccess.remove_absolute(path)

static func copy_recursive(src: String, dst: String) -> void:
	if FileAccess.file_exists(src):
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		DirAccess.copy_absolute(src, dst)
	elif DirAccess.dir_exists_absolute(src):
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
