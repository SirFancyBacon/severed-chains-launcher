extends RefCounted
class_name ModExtractor

# --- Public Async Entry Points ---

static func begin_extraction(buffer: PackedByteArray, repo: String, version: String, downloads_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var temp_zip = downloads_dir.path_join("temp_download.zip")
		if not _save_temp_file(buffer, temp_zip):
			callback.call_deferred(repo, version, [], "Failed to write temp archive.", false)
			return
		_process_mod_zip(temp_zip, repo, version, downloads_dir, callback, true)
	)

static func begin_local_extraction(zip_path: String, downloads_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var file_name = zip_path.get_file().get_basename()
		var repo_id = "local/" + file_name
		_process_mod_zip(zip_path, repo_id, "Local", downloads_dir, callback, false)
	)

static func begin_updater_extraction(buffer: PackedByteArray, version: String, downloads_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var temp_zip = downloads_dir.path_join("temp_update.zip")
		var target_dir = downloads_dir.path_join("updater")
		if not _save_temp_file(buffer, temp_zip):
			callback.call_deferred("self/updater", version, [], "Failed to create temp ZIP.", false)
			return
			
		_reset_directory(target_dir)
		var success = _unzip_archive(temp_zip, target_dir)
		if success: DirAccess.remove_absolute(temp_zip)
		callback.call_deferred("self/updater", version, [], "Update extracted!", success)
	)

static func begin_root_extraction(buffer: PackedByteArray, asset_url: String, target_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var is_tar = asset_url.ends_with(".tar.gz")
		var temp_path = target_dir.path_join("temp_sc_install" + (".tar.gz" if is_tar else ".zip"))
		
		if not _save_temp_file(buffer, temp_path):
			callback.call_deferred(false, "Failed to create temp archive.")
			return

		var success: bool
		if is_tar:
			success = _extract_tar(temp_path, target_dir)
		else:
			success = _unzip_archive(temp_path, target_dir)
			
		if success: DirAccess.remove_absolute(temp_path)
		var msg = "Severed Chains installed successfully!" if success else "Failed to extract core archive."
		callback.call_deferred(success, msg)
	)

# --- Core Processing Logic ---

static func _process_mod_zip(zip_path: String, repo: String, default_version: String, target_dir: String, callback: Callable, cleanup_zip: bool) -> void:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		if cleanup_zip: DirAccess.remove_absolute(zip_path)
		callback.call_deferred(repo, default_version, [], "Failed to open ZIP.", false)
		return

	var files = zip.get_files()
	if files.is_empty():
		zip.close()
		if cleanup_zip: DirAccess.remove_absolute(zip_path)
		callback.call_deferred(repo, default_version, [], "ZIP is empty.", false)
		return

	# Detect if this is a GitHub zipball (all files wrapped in one master folder)
	var root_folder = ""
	var has_single_root = true
	for f in files:
		var parts = f.split("/", false)
		if parts.size() > 0:
			var top = parts[0] + "/"
			if root_folder == "":
				root_folder = top
			elif not f.begins_with(root_folder):
				has_single_root = false
				break

	if not has_single_root:
		root_folder = ""

	var mod_name = repo.split("/")[1] if "/" in repo else repo
	_reset_directory(target_dir)

	for f in files:
		if f.ends_with("/"): continue
		
		# Strip the GitHub master folder if it exists, otherwise extract as-is
		var clean_path = f.trim_prefix(root_folder) if root_folder != "" else f
		if clean_path.is_empty(): continue

		var out_path = target_dir.path_join(clean_path)
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		
		var out_file = FileAccess.open(out_path, FileAccess.WRITE)
		if out_file:
			out_file.store_buffer(zip.read_file(f))
			out_file.close()

	zip.close()
	if cleanup_zip: DirAccess.remove_absolute(zip_path)

	callback.call_deferred(repo, default_version, [], mod_name + " ready!", true)

# --- Private Utilities ---

static func _save_temp_file(buffer: PackedByteArray, path: String) -> bool:
	# CRITICAL: Force creation of the parent directory before saving the file
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file: return false
	file.store_buffer(buffer)
	file.close()
	return true

static func _unzip_archive(zip_path: String, target_dir: String) -> bool:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK: return false
	
	for file in zip.get_files():
		var target_path = target_dir.path_join(file)
		if file.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target_path)
		else:
			DirAccess.make_dir_recursive_absolute(target_path.get_base_dir())
			var out_file = FileAccess.open(target_path, FileAccess.WRITE)
			if out_file:
				out_file.store_buffer(zip.read_file(file))
				out_file.close()
	zip.close()
	return true

static func _extract_tar(tar_path: String, target_dir: String) -> bool:
	return OS.execute("tar", ["-xzf", tar_path, "-C", target_dir]) == 0

static func _reset_directory(dir_path: String) -> void:
	if DirAccess.dir_exists_absolute(dir_path):
		FileUtiles.remove_dir_recursive(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
