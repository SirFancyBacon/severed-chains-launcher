extends Node
class_name ModService

signal status_updated(message: String)
signal mod_list_ready(mod_list: Array, installed_data: Dictionary)
signal mod_added(repo: String, current_version: String, is_enabled: bool)
signal mod_remote_info_updated(repo: String, tag: String, download_url: String, current_version: String)
signal mod_api_error(repo: String, current_version: String, is_rate_limited: bool)
signal download_progress(repo: String, current: int, total: int)
signal extraction_started(repo: String)
signal mod_uninstalled(repo: String)

var base_dir: String = ""
var manager_dir: String = ""
var downloads_dir: String = ""
var game_mods_dir: String = ""
var mod_list_file: String = ""
var state_file: String = ""

var default_mod_list: Array = [
	"avionanx/Stardust-Indicators",
	"Zychronix/icon-turn-order",
	"avionanx/tlot",
	"pkolb-dev/Archipelagoon",
	"Ink230/irongoon",
	"DennytXVII/BattleRewardsMod"
]

var fetch_queue: Array = []
var active_repo: String = ""
var downloading_repo: String = ""
var downloading_version: String = ""
var download_queue: Array = []
var is_processing_download: bool = false

@onready var github_api: HTTPRequest = $GitHubAPI
@onready var download_api: HTTPRequest = $DownloadAPI
@onready var local_zip_dialog: FileDialog = $LocalZipDialog

func _ready() -> void:
	github_api.request_completed.connect(_on_github_api_request_completed)
	download_api.request_completed.connect(_on_download_api_request_completed)
	local_zip_dialog.file_selected.connect(_on_local_zip_selected)

func _process(_delta: float) -> void:
	if is_processing_download and download_api.get_http_client_status() == HTTPClient.STATUS_BODY:
		var total = download_api.get_body_size()
		var downloaded = download_api.get_downloaded_bytes()
		if total > 0:
			download_progress.emit(downloading_repo, downloaded, total)

func initialize_paths(root_dir: String) -> void:
	base_dir = root_dir
	manager_dir = base_dir.path_join("mod_manager_data")
	downloads_dir = manager_dir.path_join("downloads")
	mod_list_file = manager_dir.path_join("mod_list.json")
	state_file = manager_dir.path_join("installed_mods.json")
	game_mods_dir = base_dir.path_join("mods")
	
	var dir := DirAccess.open(base_dir)
	if not dir.dir_exists(downloads_dir):
		DirAccess.make_dir_recursive_absolute(downloads_dir)
	if not FileAccess.file_exists(mod_list_file):
		FileUtiles.save_json(mod_list_file, default_mod_list)
	if not FileAccess.file_exists(state_file):
		FileUtiles.save_json(state_file, {})
		
	status_updated.emit("Directories initialized.")

# --- Fetch Logic ---

func start_fetch() -> void:
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	var installed = FileUtiles.load_json(state_file, {})
	
	mod_list_ready.emit(mod_list, installed)
	fetch_queue = mod_list.duplicate()
	process_next_fetch()

func process_next_fetch() -> void:
	if fetch_queue.is_empty():
		status_updated.emit("Fetch complete.")
		active_repo = ""
		return
		
	active_repo = fetch_queue.pop_front()
	
	if active_repo.begins_with("local/"):
		var installed = FileUtiles.load_json(state_file, {})
		var current_ver = installed.get(active_repo, {}).get("version", "Local")
		mod_remote_info_updated.emit(active_repo, current_ver, "", current_ver)
		process_next_fetch()
		return

	status_updated.emit("Checking: " + active_repo)
	
	var url = "https://api.github.com/repos/" + active_repo + "/releases/latest"
	var headers = ["User-Agent: SeveredChains-ModManager"]
	
	var token_path = manager_dir.path_join("github_api_token.txt")
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		var token = token_file.get_as_text().strip_edges()
		if token != "":
			headers.append("Authorization: Bearer " + token)
	
	var installed = FileUtiles.load_json(state_file, {})
	var saved_etag = installed.get(active_repo, {}).get("etag", "")
	if saved_etag != "":
		headers.append("If-None-Match: " + saved_etag)
		
	github_api.request(url, headers)

func _on_github_api_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var installed = FileUtiles.load_json(state_file, {})
	var current_ver = installed.get(active_repo, {}).get("version", "")
	
	if response_code == 200:
		var json := JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK:
			var data = json.data
			var tag = data.get("tag_name", "")
			var assets = data.get("assets", [])
			var download_url = assets[0].get("browser_download_url", "") if not assets.is_empty() else ""
			
			var etag = ""
			for header in headers:
				if header.to_lower().begins_with("etag:"):
					etag = header.split(":", true, 1)[1].strip_edges()
					break
					
			if not installed.has(active_repo):
				installed[active_repo] = {}
			installed[active_repo]["remote_version"] = tag
			installed[active_repo]["remote_url"] = download_url
			installed[active_repo]["etag"] = etag
			FileUtiles.save_json(state_file, installed)
			
			mod_remote_info_updated.emit(active_repo, tag, download_url, current_ver)
					
	elif response_code == 304:
		var tag = installed.get(active_repo, {}).get("remote_version", "")
		var download_url = installed.get(active_repo, {}).get("remote_url", "")
		mod_remote_info_updated.emit(active_repo, tag, download_url, current_ver)
	else:
		print("Failed fetching ", active_repo, " (Status: ", response_code, ")")
		mod_api_error.emit(active_repo, current_ver, response_code == 403)
				
	process_next_fetch()

# --- Repository Management ---

func add_custom_repo(new_repo: String) -> void:
	if new_repo == "" or not "/" in new_repo:
		status_updated.emit("Invalid format. Please use 'author/repo'.")
		return
		
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	for existing_repo in mod_list:
		if existing_repo.to_lower() == new_repo.to_lower():
			status_updated.emit("Repository already exists in the list!")
			return
			
	mod_list.append(new_repo)
	FileUtiles.save_json(mod_list_file, mod_list)
	
	var installed = FileUtiles.load_json(state_file, {})
	var mod_data = installed.get(new_repo, {})
	var cur_version = mod_data.get("version", "")
	var is_enabled = mod_data.get("enabled", false)
	
	mod_added.emit(new_repo, cur_version, is_enabled)
	fetch_queue.append(new_repo)
	
	if active_repo == "":
		process_next_fetch()

func prompt_local_zip() -> void:
	local_zip_dialog.popup_centered(Vector2(600, 400))

func _on_local_zip_selected(path: String) -> void:
	status_updated.emit("Extracting local zip...")
	ModExtractor.begin_local_extraction(path, downloads_dir, _finalize_local_extraction)

func _finalize_local_extraction(repo: String, version: String, items: Array, message: String, success: bool) -> void:
	status_updated.emit(message)
	if not success: return
		
	var installed = FileUtiles.load_json(state_file, {})
	installed[repo] = {
		"version": version,
		"items": items,
		"enabled": false
	}
	FileUtiles.save_json(state_file, installed)
	
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	if not mod_list.has(repo):
		mod_list.append(repo)
		FileUtiles.save_json(mod_list_file, mod_list)
		
	start_fetch()

# --- Mod Actions ---

func toggle_mod_enabled(repo: String, is_enabled: bool) -> void:
	var installed = FileUtiles.load_json(state_file, {})
	if not installed.has(repo): return
		
	var mod_name = repo.split("/")[1]
	var mod_cache_dir = downloads_dir.path_join(mod_name)
	
	installed[repo]["enabled"] = is_enabled
	FileUtiles.save_json(state_file, installed)
	
	if is_enabled:
		if not DirAccess.dir_exists_absolute(mod_cache_dir):
			status_updated.emit("Cache missing for " + mod_name + ". Please update.")
			return
			
		DirAccess.make_dir_recursive_absolute(game_mods_dir)
		for item in installed[repo].get("items", []):
			var src = mod_cache_dir.path_join(item)
			var dst = game_mods_dir.path_join(item)
			FileUtiles.copy_recursive(src, dst)
			
		status_updated.emit("Enabled: " + mod_name)
	else:
		for item in installed[repo].get("items", []):
			var dst = game_mods_dir.path_join(item)
			if DirAccess.dir_exists_absolute(dst):
				FileUtiles.remove_dir_recursive(dst)
			elif FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
				
		status_updated.emit("Disabled: " + mod_name)

func uninstall_mod(repo: String) -> void:
	var installed = FileUtiles.load_json(state_file, {})
	if not installed.has(repo): return

	var mod_name = repo.split("/")[1]
	status_updated.emit("Uninstalling: " + mod_name + "...")

	if installed[repo].get("enabled", false):
		toggle_mod_enabled(repo, false)

	var mod_cache_dir = downloads_dir.path_join(mod_name)
	if DirAccess.dir_exists_absolute(mod_cache_dir):
		FileUtiles.remove_dir_recursive(mod_cache_dir)

	# 1. Erase from the installed tracking state
	installed.erase(repo)
	FileUtiles.save_json(state_file, installed)
	
	# 2. If it is a local mod, erase it from the core mod_list as well!
	if repo.begins_with("local/"):
		var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
		if mod_list.has(repo):
			mod_list.erase(repo)
			FileUtiles.save_json(mod_list_file, mod_list)

	mod_uninstalled.emit(repo)
	status_updated.emit(mod_name + " uninstalled.")

func queue_download(repo: String, asset_url: String, new_version: String) -> void:
	for job in download_queue:
		if job["repo"] == repo: return
	if is_processing_download and downloading_repo == repo: return
		
	download_queue.append({"repo": repo, "url": asset_url, "version": new_version})
	process_next_download()

func process_next_download() -> void:
	if is_processing_download or download_queue.is_empty(): return
		
	is_processing_download = true
	var job = download_queue.pop_front()
	
	downloading_repo = job["repo"]
	downloading_version = job["version"]
	
	var mod_name = downloading_repo.split("/")[1]
	status_updated.emit("Downloading: " + mod_name + "...")
	
	var headers = ["User-Agent: SeveredChains-ModManager"]
	download_api.request(job["url"], headers)

func _on_download_api_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		status_updated.emit("Download failed! (Code: " + str(response_code) + ")")
		is_processing_download = false
		process_next_download()
		return
		
	var mod_name = downloading_repo.split("/")[1]
	status_updated.emit("Extracting: " + mod_name + "...")
	extraction_started.emit(downloading_repo)
			
	ModExtractor.begin_extraction(body, downloading_repo, downloading_version, downloads_dir, _finalize_extraction)

func _finalize_extraction(repo: String, version: String, items: Array, message: String, success: bool) -> void:
	status_updated.emit(message)
	
	if success:
		var installed = FileUtiles.load_json(state_file, {})
		var is_enabled = installed.get(repo, {}).get("enabled", false)
		
		installed[repo] = {
			"version": version,
			"items": items,
			"enabled": is_enabled
		}
		FileUtiles.save_json(state_file, installed)
		mod_remote_info_updated.emit(repo, version, "", version)
				
	is_processing_download = false
	process_next_download()
