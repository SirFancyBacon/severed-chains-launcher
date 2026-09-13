class_name ThreadedFileIO

# --- Public Async API ---

static func scan_for_conflicts_async(source_dir: String, live_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var conflicts: Array = []
		_scan_recursive(source_dir, "", live_dir, conflicts)
		callback.call_deferred(conflicts)
	)

static func commit_install_async(repo: String, display_name: String, temp_dir: String, cache_dir: String, live_dir: String, overwrite: bool, pre_state: Dictionary, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		# 1. Clean up old deployed files if the mod was active
		if pre_state.has(repo):
			var old_items = pre_state[repo].get("items", [])
			if pre_state[repo].get("enabled", true):
				_remove_mod_files(live_dir, old_items)
				for item in old_items:
					_prune_empty_folders(live_dir, item)
					
			if DirAccess.dir_exists_absolute(cache_dir):
				FileUtiles.remove_dir_recursive(cache_dir)
				
		# 2. Extract new manifest and move to pristine cache FIRST
		var items: Array = []
		_collect_and_move(temp_dir, "", cache_dir, items)
		FileUtiles.remove_dir_recursive(temp_dir)
		
		# 3. Sweep legacy rogue jars (Passing the new manifest so we DO NOT delete them)
		_sweep_legacy_jars(repo.split("/")[1], display_name, live_dir, items)
		
		# 4. Deploy to active game folder
		_apply_mod_files(cache_dir, live_dir, items, overwrite)
		callback.call_deferred(items)
	)

static func toggle_mod_async(mod_name: String, display_name: String, cache_dir: String, live_dir: String, items: Array, is_enabled: bool, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		if is_enabled:
			_sweep_legacy_jars(mod_name, display_name, live_dir, items)
			_apply_mod_files(cache_dir, live_dir, items, true)
		else:
			_remove_mod_files(live_dir, items)
			for item in items:
				_prune_empty_folders(live_dir, item)
		callback.call_deferred()
	)

static func uninstall_mod_async(cache_dir: String, live_dir: String, items: Array, is_enabled: bool, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		if is_enabled:
			_remove_mod_files(live_dir, items)
			for item in items:
				_prune_empty_folders(live_dir, item)
				
		if DirAccess.dir_exists_absolute(cache_dir):
			FileUtiles.remove_dir_recursive(cache_dir)
			
		callback.call_deferred()
	)

# --- Internal Synchronous Logic ---

static func _scan_recursive(base_path: String, rel_path: String, target_dir: String, conflicts: Array) -> void:
	var current_dir = base_path.path_join(rel_path)
	var dir = DirAccess.open(current_dir)
	if not dir: return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_rel = rel_path.path_join(file_name)
			if dir.current_is_dir():
				_scan_recursive(base_path, item_rel, target_dir, conflicts)
			else:
				if FileAccess.file_exists(target_dir.path_join(item_rel)):
					conflicts.append(item_rel)
		file_name = dir.get_next()

static func _collect_and_move(base_path: String, rel_path: String, cache_dir: String, items: Array) -> void:
	var current_dir = base_path.path_join(rel_path)
	var dir = DirAccess.open(current_dir)
	if not dir: return
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var item_rel = rel_path.path_join(file_name)
			if dir.current_is_dir():
				_collect_and_move(base_path, item_rel, cache_dir, items)
			else:
				var src = current_dir.path_join(file_name)
				var dst = cache_dir.path_join(item_rel)
				DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
				DirAccess.copy_absolute(src, dst)
				items.append(item_rel)
		file_name = dir.get_next()

static func _apply_mod_files(cache_dir: String, live_dir: String, items: Array, overwrite: bool) -> void:
	for rel in items:
		var src = cache_dir.path_join(rel)
		var dst = live_dir.path_join(rel)
		
		if FileAccess.file_exists(dst) and not overwrite:
			continue
				
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		DirAccess.copy_absolute(src, dst)

static func _remove_mod_files(live_dir: String, items: Array) -> void:
	for rel in items:
		var dst = live_dir.path_join(rel)
		if FileAccess.file_exists(dst):
			DirAccess.remove_absolute(dst)

static func _sweep_legacy_jars(mod_repo_name: String, display_name: String, deploy_dir: String, safe_items: Array) -> void:
	var dir = DirAccess.open(deploy_dir)
	if not dir: return
	
	var core_repo = _get_core_identifier(mod_repo_name)
	var core_display = _get_core_identifier(display_name)
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".jar"):
			# Catch 22 Fix: If this exact file is in our safe installation manifest, ignore it
			if safe_items.has(file_name):
				file_name = dir.get_next()
				continue
				
			var core_file = _get_core_identifier(file_name.get_basename())
			if (core_repo.length() > 2 and core_file == core_repo) or (core_display.length() > 2 and core_file == core_display):
				dir.remove(file_name)
		file_name = dir.get_next()

static func _prune_empty_folders(base_mods_dir: String, file_relative_path: String) -> void:
	var current_dir = base_mods_dir.path_join(file_relative_path).get_base_dir()
	
	while current_dir.length() > base_mods_dir.length():
		var dir = DirAccess.open(current_dir)
		if dir and dir.get_files().is_empty() and dir.get_directories().is_empty():
			DirAccess.remove_absolute(current_dir)
			current_dir = current_dir.get_base_dir()
		else:
			break

static func _get_core_identifier(text: String) -> String:
	var clean = text.to_lower().replace("-", "").replace("_", "").replace(" ", "").replace(".", "")
	var num_idx = -1
	for i in range(clean.length()):
		var char = clean[i]
		if char >= "0" and char <= "9":
			num_idx = i
			break
			
	if num_idx != -1:
		if num_idx > 0 and clean[num_idx - 1] == "v":
			return clean.left(num_idx - 1)
		return clean.left(num_idx)
		
	return clean
