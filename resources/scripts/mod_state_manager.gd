extends Node
class_name ModStateManager

signal status_updated(message: String)
signal mod_lists_merged(merged_list: Array, installed_state: Dictionary)
signal conflict_detected(repo: String, conflicting_files: Array, temp_dir: String)
signal install_completed(repo: String, success: bool)
signal remote_info_updated(repo: String, tag: String, url: String, current_version: String)

@onready var networker: ModNetworker = $ModNetworker

var base_dir: String
var data_dir: String
var game_mods_dir: String
var backups_dir: String

func initialize_paths(root_dir: String) -> void:
	base_dir = root_dir
	data_dir = base_dir.path_join(AppConfig.MOD_DATA_DIR)
	game_mods_dir = base_dir.path_join(AppConfig.GAME_MODS_DIR)
	backups_dir = base_dir.path_join(AppConfig.BACKUPS_DIR)
	
	DirAccess.make_dir_recursive_absolute(data_dir)
	DirAccess.make_dir_recursive_absolute(game_mods_dir)
	DirAccess.make_dir_recursive_absolute(backups_dir)

# --- Dual-List Synchronization ---

func refresh_mod_list() -> void:
	status_updated.emit("Fetching official mod list...")
	
	networker.fetch_official_list(func(official_list: Array):
		var official_path = data_dir.path_join(AppConfig.OFFICIAL_LIST_FILE)
		if not official_list.is_empty():
			FileUtiles.save_json(official_path, official_list)
		else:
			official_list = FileUtiles.load_json(official_path, [])
			
		var custom_path = data_dir.path_join(AppConfig.CUSTOM_LIST_FILE)
		var custom_list = FileUtiles.load_json(custom_path, [])
		
		# Merge without duplicates
		var merged_list: Array = official_list.duplicate()
		for repo in custom_list:
			if not merged_list.has(repo):
				merged_list.append(repo)
				
		var installed_state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
		mod_lists_merged.emit(merged_list, installed_state)
		
		_check_updates_for_list(merged_list, installed_state)
	)

func add_custom_repo(repo: String) -> void:
	var custom_path = data_dir.path_join(AppConfig.CUSTOM_LIST_FILE)
	var custom_list = FileUtiles.load_json(custom_path, [])
	
	if not custom_list.has(repo):
		custom_list.append(repo)
		FileUtiles.save_json(custom_path, custom_list)
		refresh_mod_list()

# --- Update Checking ---

func _check_updates_for_list(merged_list: Array, installed_state: Dictionary) -> void:
	for repo in merged_list:
		if repo.begins_with("local/"): continue
			
		var saved_etag = installed_state.get(repo, {}).get("etag", "")
		# Changed from current_ver to current_version
		var current_version = installed_state.get(repo, {}).get("version", "") 
		
		networker.fetch_mod_release(repo, saved_etag, func(code, data, new_etag):
			if code == 200:
				var tag = data.get("tag_name", "")
				var assets = data.get("assets", [])
				var url = assets[0].get("browser_download_url", "") if not assets.is_empty() else ""
				
				# Update our state with the new ETag so we don't fetch it again next time
				if not installed_state.has(repo): installed_state[repo] = {}
				installed_state[repo]["remote_version"] = tag
				installed_state[repo]["remote_url"] = url
				installed_state[repo]["etag"] = new_etag
				FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), installed_state)
				
				remote_info_updated.emit(repo, tag, url, current_version)
			elif code == 304:
				# Not modified, use cached remote data
				var tag = installed_state.get(repo, {}).get("remote_version", "")
				var url = installed_state.get(repo, {}).get("remote_url", "")
				remote_info_updated.emit(repo, tag, url, current_version)
		)

# --- Installation & Conflict Handoff ---

func begin_installation(repo: String, url: String, version: String) -> void:
	status_updated.emit("Downloading " + repo.split("/")[1] + "...")
	
	networker.download_asset(repo, url, func(success: bool, body: PackedByteArray):
		if not success:
			status_updated.emit("Download failed for " + repo)
			return
			
		status_updated.emit("Extracting and scanning...")
		var temp_dir = data_dir.path_join("temp_extract").path_join(repo.split("/")[1])
		
		# 1. Extract ZIP to a temporary folder
		ModExtractor.begin_extraction(body, repo, version, temp_dir, func(_r, _v, _i, _m, extract_ok):
			if not extract_ok: return
				
			# 2. Push conflict scanning to a background thread
			WorkerThreadPool.add_task(func():
				var conflicts = ThreadedFileIO.scan_for_conflicts(temp_dir, game_mods_dir)
				
				# 3. Call back to the main thread safely
				call_deferred("_on_scan_completed", repo, version, temp_dir, conflicts)
			)
		)
	)

func _on_scan_completed(repo: String, version: String, temp_dir: String, conflicts: Array) -> void:
	if conflicts.is_empty():
		# No conflicts, proceed immediately
		resolve_installation(repo, version, temp_dir, true)
	else:
		# Halt and emit to the UI to ask the user for permission
		status_updated.emit("Conflicts detected in " + repo)
		conflict_detected.emit(repo, conflicts, temp_dir)

func resolve_installation(repo: String, version: String, temp_dir: String, overwrite: bool) -> void:
	status_updated.emit("Committing files...")
	
	WorkerThreadPool.add_task(func():
		var success = ThreadedFileIO.commit_install(temp_dir, game_mods_dir, backups_dir, overwrite)
		
		# Clean up temp directory
		FileUtiles.remove_dir_recursive(temp_dir)
		
		call_deferred("_finalize_install_state", repo, version, success)
	)

func _finalize_install_state(repo: String, version: String, success: bool) -> void:
	if success:
		var state = FileUtiles.load_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
		if not state.has(repo): state[repo] = {}
		state[repo]["version"] = version
		state[repo]["enabled"] = true
		FileUtiles.save_json(data_dir.path_join(AppConfig.MOD_STATE_FILE), state)
		
		status_updated.emit("Installed successfully.")
	install_completed.emit(repo, success)
