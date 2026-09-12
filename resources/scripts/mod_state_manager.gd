extends Node
class_name ModStateManager

signal status_updated(message: String)
signal mod_lists_merged(merged_list: Array, installed_state: Dictionary)
signal conflict_detected(repo: String, conflicts: Array, temp_dir: String)
signal install_completed(repo: String, success: bool)
signal remote_info_updated(repo: String, tag: String, url: String, current_version: String)

@onready var networker: ModNetworker = $ModNetworker

var base_dir: String
var data_dir: String
var cache_dir: String
var game_mods_dir: String
var backups_dir: String

func initialize_paths(root_dir: String) -> void:
	base_dir = root_dir
	data_dir = base_dir.path_join(AppConfig.MOD_DATA_DIR)
	cache_dir = base_dir.path_join(AppConfig.MOD_CACHE_DIR)
	game_mods_dir = base_dir.path_join(AppConfig.GAME_MODS_DIR)
	backups_dir = base_dir.path_join(AppConfig.BACKUPS_DIR)
	
	for dir in [data_dir, cache_dir, game_mods_dir, backups_dir]:
		DirAccess.make_dir_recursive_absolute(dir)

# --- Dual-List Synchronization ---

func refresh_mod_list() -> void:
	status_updated.emit("Fetching remote mod list...")
	
	networker.fetch_official_list(func(remote_list: Array):
		var remote_path = data_dir.path_join(AppConfig.REMOTE_LIST_FILE)
		
		if not remote_list.is_empty():
			FileUtiles.save_json(remote_path, remote_list)
			
		var custom_path = data_dir.path_join(AppConfig.CUSTOM_LIST_FILE)
		var custom_list = FileUtiles.load_json(custom_path, [])
		
		var merged_list: Array = []
		# Handle both raw strings (legacy) and dictionaries (hybrid metadata)
		for entry in remote_list:
			var repo_name = entry.get("repo", "") if entry is Dictionary else entry
			if not repo_name.is_empty() and not merged_list.has(repo_name):
				merged_list.append(repo_name)
				
		for repo in custom_list:
			if not merged_list.has(repo):
				merged_list.append(repo)
				
		var installed_state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
		mod_lists_merged.emit(merged_list, installed_state)
		
		_check_updates_for_list(merged_list, installed_state)
		status_updated.emit("Ready.")
	)

func add_custom_repo(repo: String) -> void:
	var parts = repo.split("/")
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		status_updated.emit("Invalid format. Use 'author/repo'.")
		return
		
	var custom_path = data_dir.path_join(AppConfig.CUSTOM_LIST_FILE)
	var custom_list = FileUtiles.load_json(custom_path, [])
	
	if custom_list.has(repo):
		status_updated.emit("Repository already exists.")
		return
		
	status_updated.emit("Validating repository...")
	networker.validate_repo(repo, func(is_valid: bool):
		if is_valid:
			custom_list.append(repo)
			FileUtiles.save_json(custom_path, custom_list)
			status_updated.emit("Repository added.")
			refresh_mod_list()
		else:
			status_updated.emit("Repository not found on GitHub.")
	)

# --- Update Checking ---

func _check_updates_for_list(merged_list: Array, installed_state: Dictionary) -> void:
	for repo in merged_list:
		if repo.begins_with("local/"): continue
			
		var saved_etag = installed_state.get(repo, {}).get("etag", "")
		var current_version = installed_state.get(repo, {}).get("version", "") 
		
		networker.fetch_mod_release(repo, saved_etag, func(code, data, new_etag):
			if code == 200:
				var tag = data.get("tag_name", "")
				
				# 1. Fallback to the auto-generated source zip if no assets exist
				var url = data.get("zipball_url", "") 
				var assets = data.get("assets", [])
				
				# 2. If they did upload a custom zip, override the fallback
				if not assets.is_empty():
					url = assets[0].get("browser_download_url", url)
				
				if not installed_state.has(repo): installed_state[repo] = {}
				installed_state[repo]["remote_version"] = tag
				installed_state[repo]["remote_url"] = url
				installed_state[repo]["etag"] = new_etag
				FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), installed_state)
				
				remote_info_updated.emit(repo, tag, url, current_version)
			elif code == 304:
				var tag = installed_state.get(repo, {}).get("remote_version", "")
				var url = installed_state.get(repo, {}).get("remote_url", "")
				remote_info_updated.emit(repo, tag, url, current_version)
		)

# --- Installation Pipeline ---

func begin_installation(repo: String, url: String, version: String) -> void:
	status_updated.emit("Downloading " + repo.split("/")[1] + "...")
	
	networker.download_asset(repo, url, func(success: bool, body: PackedByteArray):
		if not success:
			status_updated.emit("Download failed for " + repo)
			return
			
		status_updated.emit("Extracting...")
		var temp_dir = data_dir.path_join("temp_extract").path_join(repo.split("/")[1])
		
		ModExtractor.begin_extraction(body, repo, version, temp_dir, func(_r, _v, _i, msg, extract_ok):
			if not extract_ok: 
				call_deferred("emit_signal", "status_updated", "Error: " + msg)
				return
			call_deferred("_execute_conflict_scan", repo, version, temp_dir)
		)
	)

func install_local_zip(zip_path: String) -> void:
	var file_name = zip_path.get_file().get_basename()
	var repo = "local/" + file_name
	var version = "Local"
	var temp_dir = data_dir.path_join("temp_extract").path_join(file_name)
	
	status_updated.emit("Extracting local zip...")
	
	ModExtractor.begin_local_extraction(zip_path, temp_dir, func(_r, _v, _i, msg, extract_ok):
		if not extract_ok: 
			call_deferred("emit_signal", "status_updated", "Error: " + msg)
			return
		call_deferred("_execute_conflict_scan", repo, version, temp_dir)
	)

func _execute_conflict_scan(repo: String, version: String, temp_dir: String) -> void:
	status_updated.emit("Scanning for conflicts...")
	ThreadedFileIO.scan_for_conflicts_async(temp_dir, game_mods_dir, func(conflicts: Array):
		if conflicts.is_empty():
			resolve_installation(repo, version, temp_dir, true)
		else:
			status_updated.emit("Conflicts detected in " + repo)
			conflict_detected.emit(repo, conflicts, temp_dir)
	)

func _resolve_mod_display_name(repo: String, target_cache: String) -> String:
	var local_meta_path = target_cache.path_join("sc_mod.json")
	if FileAccess.file_exists(local_meta_path):
		var meta = FileUtiles.load_json(local_meta_path, {})
		var custom_name = meta.get("name", "")
		if not custom_name.is_empty():
			print("DEBUG: Found local sc_mod.json name -> ", custom_name)
			return custom_name
			
	var remote_path = data_dir.path_join(AppConfig.REMOTE_LIST_FILE)
	var remote_list = FileUtiles.load_json(remote_path, [])
	print("DEBUG: Loaded remote list, entries count: ", remote_list.size())
	
	for entry in remote_list:
		if entry is Dictionary:
			var entry_repo = entry.get("repo", "")
			print("DEBUG: Comparing entry repo '", entry_repo, "' with target '", repo, "'")
			if entry_repo == repo:
				var remote_name = entry.get("name", "")
				print("DEBUG: Match found! Remote name -> ", remote_name)
				if not remote_name.is_empty():
					return remote_name
				
	var parts = repo.split("/")
	print("DEBUG: No match found, falling back to repo name -> ", parts[1] if parts.size() > 1 else repo)
	return parts[1] if parts.size() > 1 else repo

func resolve_installation(repo: String, version: String, temp_dir: String, overwrite: bool) -> void:
	status_updated.emit("Committing files...")
	var target_cache = cache_dir.path_join(repo.split("/")[1])
	
	ThreadedFileIO.commit_install_async(temp_dir, target_cache, game_mods_dir, overwrite, func(items: Array):
		var state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
		if not state.has(repo): state[repo] = {}
		
		# Evaluate display name using the priority hierarchy
		var display_name = _resolve_mod_display_name(repo, target_cache)
		
		# Grab description with similar fallback safety
		var description = "No description provided."
		var local_meta_path = target_cache.path_join("sc_mod.json")
		if FileAccess.file_exists(local_meta_path):
			description = FileUtiles.load_json(local_meta_path, {}).get("description", description)
		else:
			var remote_list = FileUtiles.load_json(data_dir.path_join(AppConfig.REMOTE_LIST_FILE), [])
			for entry in remote_list:
				if entry is Dictionary and entry.get("repo", "") == repo:
					description = entry.get("description", description)
					break
		
		state[repo]["version"] = version
		state[repo]["items"] = items
		state[repo]["enabled"] = true
		state[repo]["display_name"] = display_name
		state[repo]["description"] = description
		
		FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), state)
		
		status_updated.emit("Installed: " + display_name)
		install_completed.emit(repo, true)
		if repo.begins_with("local/"): refresh_mod_list()
	)

# --- Mod Management ---

func toggle_mod_enabled(repo: String, is_enabled: bool) -> void:
	var state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
	if not state.has(repo): return
		
	state[repo]["enabled"] = is_enabled
	FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), state)
	
	var items = state[repo].get("items", [])
	var target_cache = cache_dir.path_join(repo.split("/")[1])
	var mod_name = repo.split("/")[1]
	
	status_updated.emit("Applying changes to " + mod_name + "...")
	ThreadedFileIO.toggle_mod_async(target_cache, game_mods_dir, items, is_enabled, func():
		status_updated.emit(mod_name + (" enabled." if is_enabled else " disabled."))
	)

func uninstall_mod(repo: String) -> void:
	var state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
	if not state.has(repo): return
		
	var items = state[repo].get("items", [])
	var target_cache = cache_dir.path_join(repo.split("/")[1])
	var mod_name = repo.split("/")[1]
	
	status_updated.emit("Uninstalling " + mod_name + "...")
	ThreadedFileIO.uninstall_mod_async(target_cache, game_mods_dir, items, func():
		state.erase(repo)
		FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), state)
		
		var custom_path = data_dir.path_join(AppConfig.CUSTOM_LIST_FILE)
		var custom_list = FileUtiles.load_json(custom_path, [])
		if custom_list.has(repo):
			custom_list.erase(repo)
			FileUtiles.save_json(custom_path, custom_list)
			
		status_updated.emit(mod_name + " uninstalled.")
		refresh_mod_list()
	)

# --- Token Management ---

func has_github_token() -> bool:
	var token_path = base_dir.path_join(AppConfig.TOKEN_PATH)
	return FileAccess.file_exists(token_path)

func save_github_token(token: String) -> void:
	var token_path = base_dir.path_join(AppConfig.TOKEN_PATH)
	DirAccess.make_dir_recursive_absolute(token_path.get_base_dir())
	
	var file = FileAccess.open(token_path, FileAccess.WRITE)
	if file:
		file.store_string(token)
