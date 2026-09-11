class_name ThreadedFileIO

# Scans a newly extracted mod against the live game directory to find overwrites.
# Runs on a background thread.
static func scan_for_conflicts(temp_extract_dir: String, game_mods_dir: String) -> Array:
	var conflicts: Array = []
	_scan_directory_recursive(temp_extract_dir, "", game_mods_dir, conflicts)
	return conflicts

static func _scan_directory_recursive(base_path: String, relative_path: String, target_dir: String, conflicts: Array) -> void:
	var current_dir = base_path.path_join(relative_path)
	var dir = DirAccess.open(current_dir)
	if not dir: return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_relative = relative_path.path_join(file_name)
			
			if dir.current_is_dir():
				_scan_directory_recursive(base_path, item_relative, target_dir, conflicts)
			else:
				var live_target = target_dir.path_join(item_relative)
				if FileAccess.file_exists(live_target):
					conflicts.append(item_relative)
					
		file_name = dir.get_next()

# Backs up vanilla files (if not already backed up) and moves the modded files into place.
# Runs on a background thread.
static func commit_install(temp_extract_dir: String, game_mods_dir: String, backups_dir: String, overwrite_conflicts: bool = true) -> bool:
	var files_to_move: Array = []
	_collect_files_recursive(temp_extract_dir, "", files_to_move)
	
	for relative_file in files_to_move:
		var src = temp_extract_dir.path_join(relative_file)
		var dst = game_mods_dir.path_join(relative_file)
		var backup = backups_dir.path_join(relative_file)
		
		# Handle Conflicts & Backups
		if FileAccess.file_exists(dst):
			if not overwrite_conflicts:
				continue # Skip this file if the user declined the overwrite
				
			# If a backup doesn't exist yet, this is the original vanilla file. Save it.
			if not FileAccess.file_exists(backup):
				DirAccess.make_dir_recursive_absolute(backup.get_base_dir())
				DirAccess.copy_absolute(dst, backup)
				
		# Move the modded file into the live directory
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		DirAccess.copy_absolute(src, dst)
		
	return true

static func _collect_files_recursive(base_path: String, relative_path: String, file_list: Array) -> void:
	var current_dir = base_path.path_join(relative_path)
	var dir = DirAccess.open(current_dir)
	if not dir: return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_relative = relative_path.path_join(file_name)
			if dir.current_is_dir():
				_collect_files_recursive(base_path, item_relative, file_list)
			else:
				file_list.append(item_relative)
		file_name = dir.get_next()
