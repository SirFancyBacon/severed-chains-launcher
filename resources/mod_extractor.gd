extends RefCounted
class_name ModExtractor

static func begin_extraction(buffer: PackedByteArray, repo: String, version: String, downloads_dir: String, callback: Callable) -> void:
	# Hand the data to the thread pool and pass the callback function along
	WorkerThreadPool.add_task(_extract_worker.bind(buffer, repo, version, downloads_dir, callback))

static func _extract_worker(buffer: PackedByteArray, repo: String, version: String, downloads_dir: String, callback: Callable) -> void:
	# 1. Save the memory buffer to a temporary ZIP file on disk
	var temp_zip_path = downloads_dir.path_join("temp_download.zip")
	var temp_file = FileAccess.open(temp_zip_path, FileAccess.WRITE)
	if temp_file:
		temp_file.store_buffer(buffer)
		temp_file.close()
	else:
		callback.call_deferred(repo, version, [], "Failed to create temp ZIP file.", false)
		return

	var zip := ZIPReader.new()
	if zip.open(temp_zip_path) != OK:
		DirAccess.remove_absolute(temp_zip_path)
		callback.call_deferred(repo, version, [], "Failed to open ZIP archive.", false)
		return
		
	var files := zip.get_files()
	var jar_path: String = ""
	
	# Find the .jar to determine the true root of the mod
	for file in files:
		if file.ends_with(".jar"):
			jar_path = file
			break
			
	if jar_path == "":
		zip.close()
		DirAccess.remove_absolute(temp_zip_path)
		callback.call_deferred(repo, version, [], "No .jar found. Extraction aborted.", false)
		return
		
	var true_root = jar_path.get_base_dir()
	if true_root != "":
		true_root += "/"
		
	var mod_name = repo.split("/")[1]
	var mod_cache_dir = downloads_dir.path_join(mod_name)
	
	if DirAccess.dir_exists_absolute(mod_cache_dir):
		FileUtiles.remove_dir_recursive(mod_cache_dir)
		
	DirAccess.make_dir_recursive_absolute(mod_cache_dir)
	var installed_top_level: Dictionary = {} 
	
	for file in files:
		if not file.begins_with(true_root):
			continue
			
		var clean_path = file.trim_prefix(true_root)
		if clean_path == "":
			continue
			
		var top_level_item = clean_path.split("/")[0]
		installed_top_level[top_level_item] = true
		
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
				
	zip.close()
	DirAccess.remove_absolute(temp_zip_path)
	
	# Extraction complete! Safely pass the data back to the main thread via the callback
	callback.call_deferred(repo, version, installed_top_level.keys(), mod_name + " successfully updated!", true)


static func begin_local_extraction(zip_path: String, downloads_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(_extract_local_worker.bind(zip_path, downloads_dir, callback))

static func _extract_local_worker(zip_path: String, downloads_dir: String, callback: Callable) -> void:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		callback.call_deferred("local/unknown", "N/A", [], "Failed to open local ZIP.", false)
		return

	var files := zip.get_files()
	var jar_path: String = ""
	
	for file in files:
		if file.ends_with(".jar"):
			jar_path = file
			break
			
	if jar_path == "":
		zip.close()
		callback.call_deferred("local/unknown", "N/A", [], "No .jar found in ZIP.", false)
		return
		
	var true_root = jar_path.get_base_dir()
	if true_root != "":
		true_root += "/"
		
	# Use the zip's filename as the mod name (e.g., "my_mod.zip" -> "my_mod")
	var file_name = zip_path.get_file().get_basename()
	var repo_id = "local/" + file_name
	var mod_cache_dir = downloads_dir.path_join(file_name)
	
	if DirAccess.dir_exists_absolute(mod_cache_dir):
		FileUtiles.remove_dir_recursive(mod_cache_dir)
	DirAccess.make_dir_recursive_absolute(mod_cache_dir)
	
	var installed_top_level: Dictionary = {} 
	var extracted_jar_path: String = ""
	
	for file in files:
		if not file.begins_with(true_root): continue
		var clean_path = file.trim_prefix(true_root)
		if clean_path == "": continue
			
		var top_level_item = clean_path.split("/")[0]
		installed_top_level[top_level_item] = true
		
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

	# 2. Scrape the version from the extracted JAR
	var mod_version = "Local"
	if extracted_jar_path != "":
		var jar_zip := ZIPReader.new()
		if jar_zip.open(extracted_jar_path) == OK:
			if jar_zip.file_exists("META-INF/MANIFEST.MF"):
				var manifest = jar_zip.read_file("META-INF/MANIFEST.MF").get_string_from_utf8()
				# Search the text block for standard version keys
				for line in manifest.split("\n"):
					if line.begins_with("Implementation-Version:") or line.begins_with("Plugin-Version:"):
						mod_version = line.split(":", true, 1)[1].strip_edges()
						break
			jar_zip.close()

	callback.call_deferred(repo_id, mod_version, installed_top_level.keys(), file_name + " installed!", true)


static func begin_updater_extraction(buffer: PackedByteArray, version: String, downloads_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(_extract_updater_worker.bind(buffer, version, downloads_dir, callback))

static func _extract_updater_worker(buffer: PackedByteArray, version: String, downloads_dir: String, callback: Callable) -> void:
	var temp_zip_path = downloads_dir.path_join("temp_update.zip")
	var temp_file = FileAccess.open(temp_zip_path, FileAccess.WRITE)
	if temp_file:
		temp_file.store_buffer(buffer)
		temp_file.close()
	else:
		callback.call_deferred("self/updater", version, [], "Failed to create temp ZIP.", false)
		return

	var zip := ZIPReader.new()
	if zip.open(temp_zip_path) != OK:
		DirAccess.remove_absolute(temp_zip_path)
		callback.call_deferred("self/updater", version, [], "Failed to open ZIP archive.", false)
		return
		
	var update_dir = downloads_dir.path_join("updater")
	if DirAccess.dir_exists_absolute(update_dir):
		FileUtiles.remove_dir_recursive(update_dir)
	DirAccess.make_dir_recursive_absolute(update_dir)
	
	var files := zip.get_files()
	for file in files:
		var target_path = update_dir.path_join(file)
		if file.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target_path)
		else:
			DirAccess.make_dir_recursive_absolute(target_path.get_base_dir())
			var file_data = zip.read_file(file)
			var out_file = FileAccess.open(target_path, FileAccess.WRITE)
			if out_file:
				out_file.store_buffer(file_data)
				out_file.close()
				
	zip.close()
	DirAccess.remove_absolute(temp_zip_path)
	callback.call_deferred("self/updater", version, [], "Update extracted!", true)
