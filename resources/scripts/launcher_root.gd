extends Control

const RSS_FEED_URL: String = "https://legendofdragoon.org/feed/"
const LOD_FAN_PAGE: String = "https://legendofdragoon.org/"
const GITHUB_API_URL: String = "https://api.github.com/repos/"
const LAUNCHER_REPO: String = "sirfancybacon/severed-chains-launcher"
const ENGINE_REPO: String = "Legend-of-Dragoon-Modding/Severed-Chains"

var base_dir: String = ""
var ready_update_path: String = ""

# --- UI References ---
@onready var version_label: Label = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/HeaderTitles/SubtitleLabel
@onready var launcher_update_btn: Button = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/LauncherUpdateButton
@onready var news_container: VBoxContainer = $MarginContainer/MainHBox/LeftColumn/TabContainer/News/ScrollContainer/RSSFeedList
@onready var changelog_container: VBoxContainer = $"MarginContainer/MainHBox/LeftColumn/TabContainer/SC Changelog/ScrollContainer/ChangeLogList"
@onready var launch_button: Button = $MarginContainer/MainHBox/RightColumn/LaunchButton
@onready var sc_install_btn: Button = $MarginContainer/MainHBox/RightColumn/InstallSCButton
@onready var discord_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/DiscordButton
@onready var github_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/GithubButton
@onready var lod_home_button: TextureButton = $MarginContainer/MainHBox/RightColumn/Logo
@onready var iso_dialog: AcceptDialog = $AcceptDialog
@onready var rss_http: HTTPRequest = $RSSRequest
@onready var mod_manager: Control = $"MarginContainer/MainHBox/LeftColumn/TabContainer/Mod Manager/ModManager"
@onready var gpu_option_btn: OptionButton = $MarginContainer/MainHBox/LeftColumn/TabContainer/Optional/VBoxContainer/GPUHBox/OptionButton

func _ready() -> void:
	if _handle_cli_update_handoff():
		return

	_initialize_environment()
	_initialize_settings_tab()
	_bind_ui_signals()
	_load_rss_feed()
	_fetch_changelog()

# --- Lifecycle & Boot ---

func _handle_cli_update_handoff() -> bool:
	var args = OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--apply-update" and args.size() > i + 2:
			_apply_update_and_restart(args[i + 1].to_int(), args[i + 2])
			return true
	return false

func _initialize_environment() -> void:
	launcher_update_btn.visible = false
	var app_version = ProjectSettings.get_setting("application/config/version", "1.0.0")
	version_label.text = "Version:: " + app_version

	if OS.has_feature("editor"):
		base_dir = ProjectSettings.globalize_path("res://")
	else:
		base_dir = OS.get_executable_path().get_base_dir()
		_check_for_launcher_updates()

	_check_engine_installed()
	mod_manager.initialize_paths(base_dir)

func _bind_ui_signals() -> void:
	launch_button.pressed.connect(_on_launch_pressed)
	launcher_update_btn.pressed.connect(_on_launcher_update_pressed)
	discord_button.pressed.connect(func(): OS.shell_open("https://discord.gg/rQWXgK5"))
	github_button.pressed.connect(func(): OS.shell_open("https://github.com/" + ENGINE_REPO))
	lod_home_button.pressed.connect(func(): OS.shell_open(LOD_FAN_PAGE))



# --- Settings Tab Logic ---

func _initialize_settings_tab() -> void:
	gpu_option_btn.clear()
	gpu_option_btn.add_item("Auto (Let OS Decide)", 0)
	gpu_option_btn.add_item("Discrete (High Performance)", 1)
	gpu_option_btn.add_item("Integrated (Power Saving)", 2)
	
	# Dynamically check the system state based on the OS
	var current_pref = FileUtiles.get_system_gpu_preference(base_dir)
	
	match current_pref:
		1: gpu_option_btn.select(1)
		2: gpu_option_btn.select(2)
		_: gpu_option_btn.select(0)
		
	gpu_option_btn.item_selected.connect(_on_gpu_preference_changed)

func _on_gpu_preference_changed(index: int) -> void:
	var preference = 0
	match index:
		1: preference = 1 
		2: preference = 2 
		_: preference = 0 
		
	var conf_path = base_dir.path_join("launch.conf")
	FileUtiles.write_config_value(conf_path, "GPU_PREFERENCE", str(preference))
	
	if OS.has_feature("windows"):
		FileUtiles.apply_windows_gpu_registry(preference, base_dir)

# --- Game Launch Execution ---

func _on_launch_pressed() -> void:
	var script_name = "launch.bat" if OS.has_feature("windows") else "launch"
	var script_path = base_dir.path_join(script_name)

	if not FileAccess.file_exists(script_path):
		print("Launch script not found at: ", script_path)
		return

	var pid = -1
	if OS.has_feature("windows"):
		# Bundle the command into a single string to preserve the && chain
		var cmd_string = 'cd /d "%s" && launch.bat' % base_dir
		pid = OS.create_process("cmd.exe", ["/c", cmd_string])
	else:
		FileAccess.set_unix_permissions(script_path, 493) # 0755
		pid = OS.create_process("/bin/bash", [script_path])

	if pid == -1:
		print("Failed to launch game process.")

# --- Severed Chains Engine Installer ---

func _check_engine_installed() -> void:
	var script_name = "launch.bat" if OS.has_feature("windows") else "launch"
	if FileAccess.file_exists(base_dir.path_join(script_name)):
		sc_install_btn.visible = false
	else:
		sc_install_btn.visible = true
		sc_install_btn.pressed.connect(_start_engine_install)
		iso_dialog.dialog_text = "Installation complete! Please place your Legend of Dragoon ISO files into the folder that just opened."

func _start_engine_install() -> void:
	sc_install_btn.disabled = true
	sc_install_btn.text = "Checking releases..."
	_fetch_github_release(ENGINE_REPO, func(release_data):
		if release_data.is_empty():
			sc_install_btn.text = "API Error"
			sc_install_btn.disabled = false
			return

		var asset_url = _find_os_asset_url(release_data.get("assets", []))
		if asset_url == "":
			sc_install_btn.text = "No compatible build found"
			sc_install_btn.disabled = false
			return

		sc_install_btn.text = "Downloading engine..."
		_download_asset(asset_url, func(body):
			sc_install_btn.text = "Extracting..."
			ModExtractor.begin_root_extraction(body, asset_url, base_dir, _finalize_engine_install)
		)
	)

func _finalize_engine_install(success: bool, _message: String) -> void:
	if success:
		sc_install_btn.visible = false
		var iso_dir = base_dir.path_join("isos")
		if not DirAccess.dir_exists_absolute(iso_dir):
			DirAccess.make_dir_recursive_absolute(iso_dir)
		OS.shell_open(ProjectSettings.globalize_path(iso_dir))
		iso_dialog.popup_centered()
	else:
		sc_install_btn.text = "Install Failed"
		sc_install_btn.disabled = false

# --- Launcher Self-Updater ---

func _check_for_launcher_updates() -> void:
	_fetch_github_release(LAUNCHER_REPO, func(release_data):
		if release_data.is_empty(): return
		var latest_ver = release_data.get("tag_name", "").trim_prefix("v")
		var current_ver = ProjectSettings.get_setting("application/config/version", "1.0.0").trim_prefix("v")

		if latest_ver != "" and latest_ver != current_ver:
			var asset_url = _find_os_asset_url(release_data.get("assets", []))
			if asset_url != "":
				_download_asset(asset_url, func(body):
					ModExtractor.begin_updater_extraction(body, latest_ver, base_dir.path_join("mod_manager_data"), _on_updater_extracted)
				)
	)

func _on_updater_extracted(repo: String, version: String, _items: Array, _msg: String, success: bool) -> void:
	if not success: return
	var update_dir = base_dir.path_join("mod_manager_data/updater")
	var dir = DirAccess.open(update_dir)
	if not dir: return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension() not in ["pck", "zip", "tar", "gz"]:
			if OS.has_feature("windows") and file_name.get_extension() != "exe":
				file_name = dir.get_next()
				continue
			ready_update_path = update_dir.path_join(file_name)
			break
		file_name = dir.get_next()

	if ready_update_path != "":
		launcher_update_btn.text = "Update v" + version + " Ready!"
		launcher_update_btn.visible = true

func _on_launcher_update_pressed() -> void:
	if OS.has_feature("linux") or OS.has_feature("macos"):
		FileAccess.set_unix_permissions(ready_update_path, 493)

	var pid = OS.create_process(ready_update_path, ["--apply-update", str(OS.get_process_id()), OS.get_executable_path()])
	if pid == -1:
		launcher_update_btn.text = "Error: Blocked by OS"
	else:
		get_tree().quit()

func _apply_update_and_restart(target_pid: int, original_path: String) -> void:
	var max_wait = 50
	while OS.is_process_running(target_pid) and max_wait > 0:
		OS.delay_msec(100)
		max_wait -= 1
	OS.delay_msec(500)

	var current_exe = OS.get_executable_path()
	if current_exe != original_path:
		if FileAccess.file_exists(original_path):
			DirAccess.remove_absolute(original_path)
		DirAccess.copy_absolute(current_exe, original_path)

		var current_pck = current_exe.get_basename() + ".pck"
		var original_pck = original_path.get_basename() + ".pck"
		if FileAccess.file_exists(current_pck):
			if FileAccess.file_exists(original_pck):
				DirAccess.remove_absolute(original_pck)
			DirAccess.copy_absolute(current_pck, original_pck)

		if OS.has_feature("linux") or OS.has_feature("macos") or OS.has_feature("bsd"):
			FileAccess.set_unix_permissions(original_path, 493)

		OS.create_process(original_path, [])
	get_tree().quit()

# --- Network & GitHub Helpers ---

func _fetch_github_release(repo: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		if response_code != 200:
			print("API Error on ", repo, " - Code: ", response_code)
			callback.call({})
			return
		var json = JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
			callback.call(json.data)
		else:
			callback.call({})
	)
	
	var headers = ["User-Agent: SeveredChains-Launcher"]
	var token_path = base_dir.path_join("mod_manager_data/github_api_token.txt")
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		var token = token_file.get_as_text().strip_edges()
		if token != "":
			headers.append("Authorization: Bearer " + token)
			
	http.request(GITHUB_API_URL + repo + "/releases/latest", headers)

func _download_asset(url: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		if response_code == 200:
			callback.call(body)
	)
	http.request(url, ["User-Agent: SeveredChains-Launcher"])

func _find_os_asset_url(assets: Array) -> String:
	for asset in assets:
		var name_str = asset.get("name", "").to_lower()
		if OS.has_feature("windows") and "win" in name_str:
			return asset.get("browser_download_url", "")
		elif OS.has_feature("linux") and "linux" in name_str:
			return asset.get("browser_download_url", "")
		elif OS.has_feature("macos") and "mac" in name_str:
			return asset.get("browser_download_url", "")
	return ""


func _fetch_changelog() -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		print("GitHub Response Code: ", response_code)
		if response_code != 200:
			print("Error Body: ", body.get_string_from_utf8())
			return
			
		var json = JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK and json.data is Array:
			# Grab the 20 most recent commits
			var latest_commits = json.data.slice(0, 30) 
			
			for commit_data in latest_commits:
				var commit_info = commit_data.get("commit", {})
				var message = commit_info.get("message", "No description provided.")
				var github_user = commit_data.get("author")
				var author = github_user.get("login") if github_user else commit_info.get("author", {}).get("name", "Unknown Developer")
				var date = commit_info.get("author", {}).get("date", "")
				var url = commit_data.get("html_url", "")
				
				# Split by newline to isolate the title from the body
				var split_msg = message.split("\n")
				var commit_title = split_msg[0]
				var commit_desc = ""
				
				if split_msg.size() > 1:
					commit_desc = "\n".join(split_msg.slice(1)).strip_edges()
				else:
					commit_desc = "Committed by " + author
					
				# Format the ISO 8601 date (2026-08-29T22:54:30Z -> 2026-08-29 22:54:30)
				var clean_date = date.replace("T", " ").replace("Z", "")
				
				# Spawn your UI panel here
				_spawn_changelog_item(commit_title, url, clean_date, commit_desc)
	)
	
	# Target the main branch explicitly
	var url = GITHUB_API_URL + ENGINE_REPO + "/commits?sha=main"
	var headers = ["User-Agent: SeveredChains-Launcher"]
	
	# Reuse your existing token to prevent GitHub rate limiting
	var token_path = base_dir.path_join("mod_manager_data/github_api_token.txt")
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		var token = token_file.get_as_text().strip_edges()
		if token != "":
			headers.append("Authorization: Bearer " + token)
			
	http.request(url, headers)


# --- RSS Feed Logic ---

func _load_rss_feed() -> void:
	var loading_label = Label.new()
	loading_label.name = "LoadingLabel"
	loading_label.text = "Loading news..."
	news_container.add_child(loading_label)

	rss_http.request_completed.connect(_on_rss_completed)
	rss_http.request(RSS_FEED_URL, ["User-Agent: SeveredChains-Launcher"])

func _on_rss_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var loading_node = news_container.get_node_or_null("LoadingLabel")
	if loading_node:
		loading_node.queue_free()

	if response_code != 200:
		print("Failed to fetch RSS. Status: ", response_code)
		return

	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK: return

	var in_item = false
	var current_title = ""
	var current_link = ""
	var current_date = ""
	var current_desc = ""
	var current_node = ""

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				current_node = parser.get_node_name().to_lower()
				if current_node == "item":
					in_item = true
					
			# Catch both standard text and CDATA blocks
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_item:
					var text = ""
					if parser.get_node_type() == XMLParser.NODE_TEXT:
						# Standard text uses get_node_data()
						text = parser.get_node_data().strip_edges()
					else:
						# CDATA uses get_node_name()
						text = parser.get_node_name().strip_edges()
						
					if text != "":
						match current_node:
							"title": current_title += text
							"link": current_link += text
							"pubdate": current_date += text
							"description": current_desc += text
							"content:encoded": current_desc += text
							
			XMLParser.NODE_ELEMENT_END:
				if parser.get_node_name().to_lower() == "item":
					in_item = false
					
					# 1. Strip raw HTML tags out of the description
					var regex = RegEx.new()
					regex.compile("<[^>]*>")
					var clean_desc = regex.sub(current_desc, "", true).strip_edges()
					
					# 2. Unescape XML entities like &#8217; (apostrophe) or &amp;
					clean_desc = clean_desc.xml_unescape()
					
					# 3. Truncate text so it fits nicely in the panel
					if clean_desc.length() > 200:
						clean_desc = clean_desc.substr(0, 197) + "..."
						
					# 4. Truncate time and timezone from the pubDate
					var date_parts = current_date.split(" ", false)
					if date_parts.size() >= 4:
						current_date = "%s %s %s %s" % [date_parts[0], date_parts[1], date_parts[2], date_parts[3]]
					
					_spawn_rss_item(current_title, current_link, current_date, clean_desc)
					
					# Reset variables for the next item
					current_title = ""
					current_link = ""
					current_date = ""
					current_desc = ""

func _spawn_rss_item(title: String, link: String, date: String, desc: String) -> void:
	var panel_scene = preload("res://resources/news_row.tscn")
	var panel_instance = panel_scene.instantiate()
	news_container.add_child(panel_instance)
	
	panel_instance.setup(title, link, date, desc)

func _spawn_changelog_item(title: String, link: String, date: String, desc: String) -> void:
	var panel_scene = preload("res://resources/changelog_row.tscn")
	var panel_instance = panel_scene.instantiate()
	changelog_container.add_child(panel_instance)
	
	panel_instance.setup(title, link, date, desc)
