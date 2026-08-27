extends Control
class_name ModManager

const MOD_ROW_SCENE = preload("res://resources/ModRow.tscn")

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
	"Ink230/irongoon"
]

var fetch_queue: Array = []
var active_repo: String = ""

# --- Queue System Variables ---
var downloading_repo: String = ""
var downloading_version: String = ""
var download_queue: Array = []
var is_processing_download: bool = false

@onready var repo_input: LineEdit = $MarginContainer/MainVBox/HeaderHBox/CustomRepoInput
@onready var add_repo_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddRepoButton
@onready var fetch_button: Button = $MarginContainer/MainVBox/HeaderHBox/FetchButton
@onready var update_button: Button = $MarginContainer/MainVBox/HeaderHBox/UpdateButton
@onready var status_label: Label = $MarginContainer/MainVBox/StatusLabel
@onready var mod_list_container: VBoxContainer = $MarginContainer/MainVBox/ModListScroll/ModList
@onready var github_api: HTTPRequest = $GitHubAPI
@onready var download_api: HTTPRequest = $DownloadAPI
@onready var add_local_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddLocalButton
@onready var local_zip_dialog: FileDialog = $LocalZipDialog

func _process(_delta: float) -> void:
	# Only run the math if we are actively downloading a file body
	if is_processing_download and download_api.get_http_client_status() == HTTPClient.STATUS_BODY:
		var total = download_api.get_body_size()
		var downloaded = download_api.get_downloaded_bytes()
		
		# Some servers don't send the total size immediately, so we check if total > 0
		if total > 0:
			for row in mod_list_container.get_children():
				if row.repo_id == downloading_repo:
					if row.has_method("update_progress"):
						row.update_progress(downloaded, total)
					break



func initialize_paths(root_dir: String) -> void:
	base_dir = root_dir
	
	manager_dir = base_dir.path_join("mod_manager_data")
	downloads_dir = manager_dir.path_join("downloads")
	mod_list_file = manager_dir.path_join("mod_list.json")
	state_file = manager_dir.path_join("installed_mods.json")
	game_mods_dir = base_dir.path_join("mods")
	
	initialize_directories()
	
	github_api.request_completed.connect(_on_github_api_request_completed)
	download_api.request_completed.connect(_on_download_api_request_completed)
	
	
	add_repo_btn.pressed.connect(_on_add_repo_pressed)
	fetch_button.pressed.connect(_on_fetch_button_pressed)
	# update_button.pressed.connect(_on_update_all_pressed) 
	add_local_btn.pressed.connect(func(): local_zip_dialog.popup_centered(Vector2(600, 400)))
	local_zip_dialog.file_selected.connect(_on_local_zip_selected)
	
	_on_fetch_button_pressed()

func initialize_directories() -> void:
	var dir := DirAccess.open(base_dir)
	if not dir.dir_exists(downloads_dir):
		DirAccess.make_dir_recursive_absolute(downloads_dir)
		
	if not FileAccess.file_exists(mod_list_file):
		FileUtiles.save_json(mod_list_file, default_mod_list)
		
	if not FileAccess.file_exists(state_file):
		FileUtiles.save_json(state_file, {})
		
	status_label.text = "Directories initialized."

# --- Fetch Logic ---

func _on_fetch_button_pressed() -> void:
	for child in mod_list_container.get_children():
		child.queue_free()
		
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	var installed = FileUtiles.load_json(state_file, {})
	fetch_queue = mod_list.duplicate()
	
	for repo in mod_list:
		var row = MOD_ROW_SCENE.instantiate()
		mod_list_container.add_child(row)
		
		var mod_data = installed.get(repo, {})
		var cur_version = mod_data.get("version", "")
		var is_enabled = mod_data.get("enabled", false)
		
		row.setup(repo, cur_version, is_enabled)
		row.enable_toggled.connect(_on_mod_enable_toggled)
		row.update_requested.connect(_on_mod_update_requested)
		row.uninstall_requested.connect(_on_mod_uninstall_requested)
	
	process_next_fetch()

func process_next_fetch() -> void:
	if fetch_queue.is_empty():
		status_label.text = "Fetch complete."
		active_repo = ""
		return
		
	active_repo = fetch_queue.pop_front()
	# --- LOCAL MOD INTERCEPT ---
	if active_repo.begins_with("local/"):
		var installed = FileUtiles.load_json(state_file, {})
		var current_ver = installed.get(active_repo, {}).get("version", "Local")
		for row in mod_list_container.get_children():
			if row.repo_id == active_repo:
				# Pass the installed version as the "remote" version so the UI thinks it is [Up to Date]
				row.set_remote_info(current_ver, "", current_ver) 
				break
		process_next_fetch()
		return
	# ---------------------------
	status_label.text = "Checking: " + active_repo
	
	var url = "https://api.github.com/repos/" + active_repo + "/releases/latest"
	var headers = ["User-Agent: SeveredChains-ModManager"]
	
	# Look for a user-provided token in a local text file
	var token_path = manager_dir.path_join("github_api_token.txt")
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		var token = token_file.get_as_text().strip_edges()
		if token != "":
			headers.append("Authorization: Bearer " + token)
	
	# Grab the ETag from our local state if we have one
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
			
			# Extract the ETag from the GitHub headers
			var etag = ""
			for header in headers:
				if header.to_lower().begins_with("etag:"):
					etag = header.split(":", true, 1)[1].strip_edges()
					break
					
			# Save the remote data into our state so we can reuse it later
			if not installed.has(active_repo):
				installed[active_repo] = {}
			installed[active_repo]["remote_version"] = tag
			installed[active_repo]["remote_url"] = download_url
			installed[active_repo]["etag"] = etag
			FileUtiles.save_json(state_file, installed)
			
			for row in mod_list_container.get_children():
				if row.repo_id == active_repo:
					row.set_remote_info(tag, download_url, current_ver)
					break
					
	elif response_code == 304:
		# GitHub confirmed nothing changed! Load our cached UI data.
		var tag = installed.get(active_repo, {}).get("remote_version", "")
		var download_url = installed.get(active_repo, {}).get("remote_url", "")
		
		for row in mod_list_container.get_children():
			if row.repo_id == active_repo:
				row.set_remote_info(tag, download_url, current_ver)
				break
				
	else:
		print("Failed fetching ", active_repo, " (Status: ", response_code, ")")
		for row in mod_list_container.get_children():
			if row.repo_id == active_repo:
				row.version_label.text = current_ver if current_ver != "" else "N/A"
				row.enable_check.disabled = (current_ver == "")
				if response_code == 403:
					row.status_label.text = "[API Rate Limited]"
				else:
					row.status_label.text = "[API Error]"
					
				# If it's already installed, let them at least remove it or toggle it!
				if current_ver != "":
					if "uninstall_btn" in row: row.uninstall_btn.visible = true
				break
				
	process_next_fetch()
	
# --- Toggle Logic ---

func _on_mod_enable_toggled(repo: String, is_enabled: bool) -> void:
	var installed = FileUtiles.load_json(state_file, {})
	if not installed.has(repo):
		return
		
	var mod_name = repo.split("/")[1]
	var mod_cache_dir = downloads_dir.path_join(mod_name)
	
	installed[repo]["enabled"] = is_enabled
	FileUtiles.save_json(state_file, installed)
	
	if is_enabled:
		if not DirAccess.dir_exists_absolute(mod_cache_dir):
			status_label.text = "Cache missing for " + mod_name + ". Please update."
			return
			
		DirAccess.make_dir_recursive_absolute(game_mods_dir)
		for item in installed[repo].get("items", []):
			var src = mod_cache_dir.path_join(item)
			var dst = game_mods_dir.path_join(item)
			FileUtiles.copy_recursive(src, dst)
			
		status_label.text = "Enabled: " + mod_name
	else:
		for item in installed[repo].get("items", []):
			var dst = game_mods_dir.path_join(item)
			if DirAccess.dir_exists_absolute(dst):
				FileUtiles.remove_dir_recursive(dst)
			elif FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
				
		status_label.text = "Disabled: " + mod_name


func _on_mod_uninstall_requested(repo: String) -> void:
	var installed = FileUtiles.load_json(state_file, {})
	if not installed.has(repo): 
		return

	var mod_name = repo.split("/")[1]
	status_label.text = "Uninstalling: " + mod_name + "..."

	# 1. Disable it first (this safely removes it from the live game folder)
	if installed[repo].get("enabled", false):
		_on_mod_enable_toggled(repo, false)

	# 2. Delete the cached download ZIP/folder
	var mod_cache_dir = downloads_dir.path_join(mod_name)
	if DirAccess.dir_exists_absolute(mod_cache_dir):
		FileUtiles.remove_dir_recursive(mod_cache_dir)

	# 3. Remove it from the installed_mods.json tracking state
	installed.erase(repo)
	FileUtiles.save_json(state_file, installed)

	# 4. Refresh the UI row to show it as "Not Installed"
	for row in mod_list_container.get_children():
		if row.repo_id == repo:
			# Pass an empty string for the installed version to reset it
			row.set_remote_info(row.latest_version, row.asset_download_url, "")
			row.enable_check.button_pressed = false
			break
			
	status_label.text = mod_name + " uninstalled."


# --- Queued Download & Extraction Logic ---

func _on_mod_update_requested(repo: String, asset_url: String, new_version: String) -> void:
	# Prevent duplicate jobs if the mod is already in the queue
	for job in download_queue:
		if job["repo"] == repo: return
		
	# If we are currently downloading this exact mod, ignore the click
	if is_processing_download and downloading_repo == repo: return
		
	download_queue.append({"repo": repo, "url": asset_url, "version": new_version})
	process_next_download()

func process_next_download() -> void:
	if is_processing_download or download_queue.is_empty():
		return
		
	is_processing_download = true
	var job = download_queue.pop_front()
	
	downloading_repo = job["repo"]
	downloading_version = job["version"]
	
	var mod_name = downloading_repo.split("/")[1]
	status_label.text = "Downloading: " + mod_name + "..."
	
	var headers = ["User-Agent: SeveredChains-ModManager"]
	download_api.request(job["url"], headers)

func _on_download_api_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		status_label.text = "Download failed! (Code: " + str(response_code) + ")"
		is_processing_download = false
		process_next_download()
		return
		
	var mod_name = downloading_repo.split("/")[1]
	status_label.text = "Extracting: " + mod_name + "..."
	
	# Make the progress bar "bounce" to show it is extracting
	for row in mod_list_container.get_children():
		if row.repo_id == downloading_repo and row.has_method("update_progress"):
			row.install_progress.max_value = 0 # Triggers indeterminate mode in Godot
			
	ModExtractor.begin_extraction(body, downloading_repo, downloading_version, downloads_dir, _finalize_extraction)

func _finalize_extraction(repo: String, version: String, items: Array, message: String, success: bool) -> void:
	status_label.text = message
	
	if success:
		var installed = FileUtiles.load_json(state_file, {})
		var is_enabled = installed.get(repo, {}).get("enabled", false)
		
		installed[repo] = {
			"version": version,
			"items": items,
			"enabled": is_enabled
		}
		FileUtiles.save_json(state_file, installed)
		
		for row in mod_list_container.get_children():
			if row.repo_id == repo:
				row.set_remote_info(version, "", version)
				break
				
	# Release the queue lock and trigger the next item in line
	is_processing_download = false
	process_next_download()


func _on_add_repo_pressed() -> void:
	# 1. Validate the input
	var new_repo = repo_input.text.strip_edges()
	if new_repo == "" or not "/" in new_repo:
		status_label.text = "Invalid format. Please use 'author/repo'."
		return
		
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	
	# Check for duplicates using a case-insensitive check
	for existing_repo in mod_list:
		if existing_repo.to_lower() == new_repo.to_lower():
			status_label.text = "Repository already exists in the list!"
			return
			
	# 2. Save it to our persistent list
	mod_list.append(new_repo)
	FileUtiles.save_json(mod_list_file, mod_list)
	
	repo_input.text = "" # Clear the input box
	
	# 3. Spawn the new visual row
	var installed = FileUtiles.load_json(state_file, {})
	var row = MOD_ROW_SCENE.instantiate()
	mod_list_container.add_child(row)
	
	var mod_data = installed.get(new_repo, {})
	var cur_version = mod_data.get("version", "")
	var is_enabled = mod_data.get("enabled", false)
	
	row.setup(new_repo, cur_version, is_enabled)
	row.enable_toggled.connect(_on_mod_enable_toggled)
	row.update_requested.connect(_on_mod_update_requested)
	row.uninstall_requested.connect(_on_mod_uninstall_requested)
	
	# 4. Trigger an immediate API check for just this new repo
	fetch_queue.append(new_repo)
	if active_repo == "":
		process_next_fetch()


func _on_local_zip_selected(path: String) -> void:
	status_label.text = "Extracting local zip..."
	ModExtractor.begin_local_extraction(path, downloads_dir, _finalize_local_extraction)

func _finalize_local_extraction(repo: String, version: String, items: Array, message: String, success: bool) -> void:
	status_label.text = message
	if not success: return
		
	var installed = FileUtiles.load_json(state_file, {})
	installed[repo] = {
		"version": version,
		"items": items,
		"enabled": false # Let the user manually enable it after installing
	}
	FileUtiles.save_json(state_file, installed)
	
	var mod_list = FileUtiles.load_json(mod_list_file, default_mod_list)
	if not mod_list.has(repo):
		mod_list.append(repo)
		FileUtiles.save_json(mod_list_file, mod_list)
		
	# Instantly refresh the UI to spawn the new row
	_on_fetch_button_pressed()
