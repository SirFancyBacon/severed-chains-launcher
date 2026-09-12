class_name ThreadedFileIO

# --- Public Async API ---

static func scan_for_conflicts_async(source_dir: String, live_dir: String, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var conflicts: Array = []
		_scan_recursive(source_dir, "", live_dir, conflicts)
		callback.call_deferred(conflicts)
	)

static func commit_install_async(temp_dir: String, cache_dir: String, live_dir: String, overwrite: bool, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var items: Array = []
		_collect_and_move(temp_dir, "", cache_dir, items)
		FileUtiles.remove_dir_recursive(temp_dir)
		
		_apply_mod_files(cache_dir, live_dir, items, overwrite)
		callback.call_deferred(items)
	)

static func toggle_mod_async(cache_dir: String, live_dir: String, items: Array, is_enabled: bool, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		if is_enabled:
			_apply_mod_files(cache_dir, live_dir, items, true)
		else:
			_remove_mod_files(live_dir, items)
		callback.call_deferred()
	)

static func uninstall_mod_async(cache_dir: String, live_dir: String, items: Array, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		_remove_mod_files(live_dir, items)
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
