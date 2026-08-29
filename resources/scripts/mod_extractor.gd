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
		DirAccess.remove_absolute(temp_zip)
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
			
		DirAccess.remove_absolute(temp_path)
		var msg = "Severed Chains installed successfully!" if success else "Failed to extract core archive."
		callback.call_deferred(success, msg)
	)

# --- Core Processing Logic ---

static func _process_mod_zip(zip_path: String, repo: String, default_version: String, downloads_dir: String, callback: Callable, cleanup_zip: bool) -> void:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		if cleanup_zip: DirAccess.remove_absolute(zip_path)
		callback.call_deferred(repo, default_version, [], "Failed to open ZIP archive.", false)
		return

	var files := zip.get_files()
	var jar_path: String = ""
	for file in files:
		if file.ends_with(".jar"):
			jar_path = file
			break

	if jar_path == "":
		zip.close()
		if cleanup_zip: DirAccess.remove_absolute(zip_path)
		callback.call_deferred(repo, default_version, [], "No .jar found in archive.", false)
		return

	var true_root = jar_path.get_base_dir()
	if true_root != "": true_root += "/"

	var mod_name = repo.split("/")[1]
	var mod_cache_dir = downloads_dir.path_join(mod_name)
	_reset_directory(mod_cache_dir)

	var installed_top_level: Dictionary = {}
	var extracted_jar_path: String = ""

	for file in files:
		if not file.begins_with(true_root): continue
		var clean_path = file.trim_prefix(true_root)
		if clean_path == "": continue

		installed_top_level[clean_path.split("/")[0]] = true
		var target_path = mod_cache_dir.path_join(clean_path)

		if file.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target_path)
		else:
			DirAccess.make_dir_recursive_absolute(target_path.get_base_dir())
			var file_data = zip.read_file(file)
			var out_file = FileAccess.open(target_path, FileAccess.WRITE)
			if out_file:
				out_file.store_buffer(file_data)
				out_file.close()
				if clean_path.ends_with(".jar"):
					extracted_jar_path = target_path

	zip.close()
	if cleanup_zip: DirAccess.remove_absolute(zip_path)

	var final_version = _read_manifest_version(extracted_jar_path) if default_version == "Local" else default_version
	callback.call_deferred(repo, final_version, installed_top_level.keys(), mod_name + " ready!", true)

# --- Private Utilities ---

static func _save_temp_file(buffer: PackedByteArray, path: String) -> bool:
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

static func _read_manifest_version(jar_path: String) -> String:
	if jar_path == "": return "Local"
	var zip := ZIPReader.new()
	if zip.open(jar_path) != OK: return "Local"
	
	var version = "Local"
	if zip.file_exists("META-INF/MANIFEST.MF"):
		var manifest = zip.read_file("META-INF/MANIFEST.MF").get_string_from_utf8()
		for line in manifest.split("\n"):
			if line.begins_with("Implementation-Version:") or line.begins_with("Plugin-Version:"):
				version = line.split(":", true, 1)[1].strip_edges()
				break
	zip.close()
	return version
