extends Control

var base_dir: String = ""
var ready_update_path: String = ""

# --- UI References ---
@onready var version_label: Label = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/HeaderTitles/SubtitleLabel
@onready var launcher_update_btn: Button = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/LauncherUpdateButton
@onready var news_container: VBoxContainer = $MarginContainer/MainHBox/LeftColumn/TabContainer/News/ScrollContainer/RSSFeedList
@onready var changelog_container: VBoxContainer = $"MarginContainer/MainHBox/LeftColumn/TabContainer/SC Changelog/ScrollContainer/ChangeLogList"
@onready var mod_manager: Control = $"MarginContainer/MainHBox/LeftColumn/TabContainer/Mod Manager/ModManager"
@onready var issues_discord_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/IssuesHBox/ReportIssuesLoDDiscord
@onready var issues_github_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/IssuesHBox/ReportIssueSCGithub
@onready var issues_launcher_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/IssuesHBox/ReportIssuesLauncher
@onready var open_folder_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/FileUtilsHBox/OpenGameDir
@onready var open_iso_folder_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/FileUtilsHBox/OpenGameIsoDir
@onready var open_launcher_folder_button: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/FileUtilsHBox2/OpenLauncherDir
@onready var setup_guide_pc: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/SetupGuidesHBox/OpenSetupGuidePC
@onready var setup_guide_steam: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/SetupGuidesHBox/OpenSetupGuideSD
@onready var purge_gamefiles_btn: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Help/ScrollContainer/VBoxContainer/FileUtilsHBox2/PurgeGameFiles
@onready var gpu_option_btn: OptionButton = $MarginContainer/MainHBox/LeftColumn/TabContainer/Misc/ScrollContainer/VBoxContainer/GPUHBox/OptionButton
@onready var add_token_btn: Button = $MarginContainer/MainHBox/LeftColumn/TabContainer/Misc/ScrollContainer/VBoxContainer/AddGitTokenButton
@onready var launch_button: Button = $MarginContainer/MainHBox/RightColumn/LaunchButton
@onready var sc_install_btn: Button = $MarginContainer/MainHBox/RightColumn/InstallSCButton
@onready var discord_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/DiscordButton
@onready var github_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/GithubButton
@onready var lod_home_button: TextureButton = $MarginContainer/MainHBox/RightColumn/Logo
@onready var iso_dialog: AcceptDialog = $AcceptDialog
@onready var rss_http: HTTPRequest = $RSSRequest


var token_dialog: ConfirmationDialog
var token_input: LineEdit
var pending_update_url: String = ""
var pending_update_version: String = ""
var update_progress_dialog: AcceptDialog
var game_pid: int = -1
var active_sc_dir: String = ""
var last_launch_time: int = 0
var game_log_path: String = ""


# --- Lifecycle & Boot ---

func _ready() -> void:
	if _handle_cli_update_handoff():
		return

	_initialize_environment()
	_initialize_settings_tab()
	_bind_ui_signals()
	_load_rss_feed()
	_fetch_changelog()
	
	AppLogger.info("Launcher UI initialized successfully.")

func _handle_cli_update_handoff() -> bool:
	var args = OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--apply-update" and args.size() > i + 2:
			_apply_update_and_restart(args[i + 1].to_int(), args[i + 2])
			return true
	return false

func _initialize_environment() -> void:
	call_deferred("_apply_dpi_scaling")
	launcher_update_btn.visible = false
	var app_version = ProjectSettings.get_setting("application/config/version", "1.0.0")
	version_label.text = "Version:: " + app_version

	if OS.has_feature("editor"):
		base_dir = ProjectSettings.globalize_path("res://")
	else:
		base_dir = OS.get_executable_path().get_base_dir()
	
	active_sc_dir = base_dir.path_join(AppConfig.SC_STABLE_DIR)
	
	_migrate_legacy_installation() # Remove eventually
	
	_setup_token_dialog()
	_update_token_button_state()
	_setup_update_dialog()
	_check_for_launcher_updates()
	_check_engine_installed()
	_check_launch_readiness()
	mod_manager.initialize_paths(base_dir, active_sc_dir)

func _bind_ui_signals() -> void:
	launch_button.pressed.connect(_on_launch_pressed)
	launcher_update_btn.pressed.connect(_on_launcher_update_pressed)
	
	discord_button.pressed.connect(func(): OS.shell_open(AppConfig.LOD_FAN_DISCORD))
	github_button.pressed.connect(func(): OS.shell_open("https://github.com/" + AppConfig.ENGINE_REPO))
	lod_home_button.pressed.connect(func(): OS.shell_open(AppConfig.LOD_FAN_PAGE))
	add_token_btn.pressed.connect(_on_add_token_btn_pressed)
	purge_gamefiles_btn.pressed.connect(_purge_game_installation)
	
	issues_discord_button.pressed.connect(func(): OS.shell_open(AppConfig.LOD_FAN_DISCORD_HELP))
	issues_github_button.pressed.connect(func(): OS.shell_open("https://github.com/" + AppConfig.ENGINE_REPO + "/issues"))
	issues_launcher_button.pressed.connect(func(): OS.shell_open("https://github.com/" + AppConfig.LAUNCHER_REPO + "/issues"))
	
	open_folder_button.pressed.connect(func(): OS.shell_open(active_sc_dir))
	open_iso_folder_button.pressed.connect(func(): OS.shell_open(active_sc_dir.path_join("isos")))
	open_launcher_folder_button.pressed.connect(func(): OS.shell_open(base_dir))
	
	setup_guide_pc.pressed.connect(func(): OS.shell_open("https://legendofdragoon.org/guides/setup-severed-chains/"))
	setup_guide_steam.pressed.connect(func(): OS.shell_open("https://legendofdragoon.org/guides/setup-steamdeck/"))

func _check_launch_readiness() -> void:
	var validation = FileUtiles.validate_iso_directory(active_sc_dir)
	
	if validation["valid"]:
		launch_button.disabled = false
		launch_button.tooltip_text = "All 4 discs found. Ready to launch!"
	else:
		launch_button.disabled = true
		launch_button.tooltip_text = validation["message"]

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if active_sc_dir != "": 
			_check_launch_readiness()


func _apply_dpi_scaling() -> void:
	var screen_size = DisplayServer.screen_get_size()
	var scale_factor = DisplayServer.screen_get_scale()
	
	var window = get_window()
	
	# Manually force scaling on high-resolution displays if the OS reports 1.0
	if scale_factor <= 1.0:
		if screen_size.x >= 3840:
			scale_factor = 2.0 # 4K: Scales 960x540 to 1920x1080
		elif screen_size.x >= 1920:
			scale_factor = 1.5 # 1080p: Scales 960x540 to 1440x810
			
	# Apply the new size if scaled
	if scale_factor > 1.0:
		window.size = Vector2i(960 * scale_factor, 540 * scale_factor)
		
	# Force the window strictly to the primary monitor's index
	window.current_screen = DisplayServer.get_primary_screen()
	window.move_to_center()

# --- Settings Tab Logic ---

func _initialize_settings_tab() -> void:
	gpu_option_btn.clear()
	gpu_option_btn.add_item("Auto (Let OS Decide)", 0)
	gpu_option_btn.add_item("Discrete (High Performance)", 1)
	gpu_option_btn.add_item("Integrated (Power Saving)", 2)
	
	var conf_path = active_sc_dir.path_join(AppConfig.LAUNCH_CONF)
	
	# Pass "-1" as the default to detect a first-time run
	var saved_pref_str = FileUtiles.read_config_value(conf_path, "GPU_PREFERENCE", "-1")
	var current_pref = saved_pref_str.to_int()
	
	if current_pref == -1:
		current_pref = 1 
		FileUtiles.write_config_value(conf_path, "GPU_PREFERENCE", str(current_pref))
		if OS.has_feature("windows"):
			FileUtiles.apply_windows_gpu_registry(current_pref, base_dir)
	
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
		
	var conf_path = base_dir.path_join(AppConfig.LAUNCH_CONF)
	FileUtiles.write_config_value(conf_path, "GPU_PREFERENCE", str(preference))
	
	if OS.has_feature("windows"):
		FileUtiles.apply_windows_gpu_registry(preference, base_dir)


# --- Game Launch Execution ---

func _on_launch_pressed() -> void:
	if game_pid != -1 and OS.is_process_running(game_pid):
		return 
		
	var script_name = "launch.bat" if OS.has_feature("windows") else "launch"
	var script_path = active_sc_dir.path_join(script_name)

	if not FileAccess.file_exists(script_path):
		AppLogger.error("Launch script not found at: " + script_path)
		_show_crash_popup("Launch script not found at:\n" + script_path)
		return

	launch_button.disabled = true
	launch_button.text = "Running..."
	AppLogger.info("Attempting to launch game process...")
	
	# Establish the log path inside mod_manager_data
	game_log_path = base_dir.path_join(AppConfig.MOD_DATA_DIR).path_join("latest_launch.log")

	if OS.has_feature("windows"):
		var cmd_string = 'cd /d "%s" && launch.bat > "%s" 2>&1' % [active_sc_dir, game_log_path]
		game_pid = OS.create_process("cmd.exe", ["/c", cmd_string])
	else:
		FileAccess.set_unix_permissions(script_path, 493)
		var cmd_string = "cd '%s' && ./launch > '%s' 2>&1" % [active_sc_dir, game_log_path]
		game_pid = OS.create_process("/bin/bash", ["-c", cmd_string])

	if game_pid != -1:
		AppLogger.info("Game process successfully spawned with PID: " + str(game_pid))
		last_launch_time = Time.get_ticks_msec()
		_start_process_monitor()
	else:
		AppLogger.error("OS refused to spawn the game process.")
		launch_button.disabled = false
		launch_button.text = "Launch"
		_show_crash_popup("OS refused to spawn the game process.")

func _start_process_monitor() -> void:
	var monitor = Timer.new()
	monitor.wait_time = 2.0
	add_child(monitor)
	
	monitor.timeout.connect(func():
		if not OS.is_process_running(game_pid):
			launch_button.disabled = false
			launch_button.text = "Launch"
			
			var uptime = Time.get_ticks_msec() - last_launch_time
			if uptime < 5000:
				AppLogger.error("Game process crashed immediately. Uptime: " + str(uptime) + "ms")
				var log_contents = "Unknown error."
				if FileAccess.file_exists(game_log_path):
					var file = FileAccess.open(game_log_path, FileAccess.READ)
					if file: log_contents = file.get_as_text()
				
				_show_crash_popup("Severed Chains crashed immediately. Log output:\n\n" + log_contents.left(1000), game_log_path)
			else:
				AppLogger.info("Game process exited cleanly.")
				
			game_pid = -1
			monitor.queue_free()
	)
	monitor.start()


# --- Severed Chains Engine Installer ---

func _check_engine_installed() -> void:
	var script_name = "launch.bat" if OS.has_feature("windows") else "launch"
	if FileAccess.file_exists(active_sc_dir.path_join(script_name)):
		sc_install_btn.visible = false
	else:
		sc_install_btn.visible = true
		if not sc_install_btn.pressed.is_connected(_start_engine_install):
			sc_install_btn.pressed.connect(_start_engine_install)
		iso_dialog.dialog_text = "Installation complete! Please place your Legend of Dragoon image files into the folder that just opened."

func _start_engine_install() -> void:
	sc_install_btn.disabled = true
	sc_install_btn.text = "Checking releases..."
	AppLogger.info("Starting engine installation process...")
	
	_fetch_github_release(AppConfig.ENGINE_REPO, func(release_data):
		if release_data.is_empty():
			sc_install_btn.text = "API Error"
			sc_install_btn.disabled = false
			AppLogger.error("Failed to retrieve engine release data.")
			return

		var asset_url = _find_os_asset_url(release_data.get("assets", []))
		if asset_url == "":
			sc_install_btn.text = "No compatible build found"
			sc_install_btn.disabled = false
			AppLogger.error("No compatible OS asset found in engine release.")
			return

		sc_install_btn.text = "Downloading engine..."
		AppLogger.info("Downloading engine release asset...")
		_download_asset(asset_url, func(body):
			sc_install_btn.text = "Extracting..."
			ModExtractor.begin_root_extraction(body, asset_url, active_sc_dir, _finalize_engine_install)
		)
	)

func _finalize_engine_install(success: bool, _message: String) -> void:
	if success:
		AppLogger.info("Engine installation finalized successfully.")
		sc_install_btn.visible = false
		var iso_dir = active_sc_dir.path_join("isos")
		
		if not DirAccess.dir_exists_absolute(iso_dir):
			DirAccess.make_dir_recursive_absolute(iso_dir)
			
		OS.shell_open(ProjectSettings.globalize_path(iso_dir))
		iso_dialog.popup_centered()
	else:
		AppLogger.error("Engine installation failed: " + _message)
		sc_install_btn.text = "Install Failed"
		sc_install_btn.disabled = false


# --- Launcher Self-Updater ---

func _check_for_launcher_updates() -> void:
	_fetch_github_release(AppConfig.LAUNCHER_REPO, func(release_data):
		if release_data.is_empty(): return
		
		var latest_ver = release_data.get("tag_name", "").trim_prefix("v")
		var current_ver = ProjectSettings.get_setting("application/config/version", "1.0.0").trim_prefix("v")

		if latest_ver != "" and latest_ver != current_ver:
			AppLogger.info("Launcher update v" + latest_ver + " is available.")
			var asset_url = _find_os_asset_url(release_data.get("assets", []))
			if asset_url != "":
				pending_update_url = asset_url
				pending_update_version = latest_ver
				launcher_update_btn.text = "Update v" + latest_ver + " Available"
				launcher_update_btn.visible = true
				launcher_update_btn.queue_redraw()
	)

func _on_launcher_update_pressed() -> void:
	if ready_update_path != "":
		# STEP 2: Extraction finished previously, restart the app
		if OS.has_feature("linux") or OS.has_feature("macos"):
			FileAccess.set_unix_permissions(ready_update_path, 493)

		var pid = OS.create_process(ready_update_path, ["--apply-update", str(OS.get_process_id()), OS.get_executable_path()])
		if pid == -1:
			AppLogger.error("OS blocked restarting the launcher for update.")
			launcher_update_btn.text = "Error: Blocked by OS"
		else:
			AppLogger.info("Applying update and restarting launcher...")
			get_tree().quit()
			
	elif pending_update_url != "":
		# STEP 1: Fetching the update
		launcher_update_btn.disabled = true
		update_progress_dialog.dialog_text = "Downloading v%s...\nThis may take a moment." % pending_update_version
		update_progress_dialog.popup_centered()
		AppLogger.info("Starting launcher update download...")
		
		_download_asset(pending_update_url, func(body):
			if body.is_empty():
				AppLogger.error("Failed to download launcher update asset.")
				update_progress_dialog.hide()
				launcher_update_btn.text = "Download Failed"
				launcher_update_btn.disabled = false
				return
				
			update_progress_dialog.dialog_text = "Extracting files..."
			ModExtractor.begin_updater_extraction(body, pending_update_version, base_dir.path_join("mod_manager_data"), _on_updater_extracted)
		)

func _on_updater_extracted(repo: String, version: String, _items: Array, _msg: String, success: bool) -> void:
	if not success: 
		AppLogger.error("Extraction of launcher update failed: " + _msg)
		update_progress_dialog.hide()
		launcher_update_btn.text = "Extraction Failed"
		launcher_update_btn.disabled = false
		return
	
	var update_dir = base_dir.path_join("mod_manager_data/updater")
	var dir = DirAccess.open(update_dir)
	if not dir:
		AppLogger.error("Failed to open updater extraction directory: " + update_dir)
		return

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

	update_progress_dialog.hide()

	if ready_update_path != "":
		AppLogger.info("Launcher update extracted and ready to apply.")
		launcher_update_btn.text = "Restart to Apply Update"
		launcher_update_btn.disabled = false
		launcher_update_btn.queue_redraw()

func _apply_update_and_restart(target_pid: int, original_path: String) -> void:
	var max_wait = 50
	while OS.is_process_running(target_pid) and max_wait > 0:
		OS.delay_msec(100)
		max_wait -= 1
	# Give Windows extra breathing room to fully release file locks on exit
	OS.delay_msec(1000) 

	var current_exe = OS.get_executable_path()
	AppLogger.info("Applying update. Current running exe: " + current_exe + " | Target path: " + original_path)

	if current_exe != original_path:
		# Retry loop to handle Windows file-locking race conditions
		var success = false
		for attempt in range(5):
			if FileAccess.file_exists(original_path):
				var remove_err = DirAccess.remove_absolute(original_path)
				if remove_err != OK:
					AppLogger.warning("Attempt %d: Failed to remove old executable at %s (Error: %d). Retrying..." % [attempt + 1, original_path, remove_err])
					OS.delay_msec(300)
					continue
			
			var copy_err = DirAccess.copy_absolute(current_exe, original_path)
			if copy_err == OK:
				success = true
				AppLogger.info("Successfully copied new executable to: " + original_path)
				break
			else:
				AppLogger.warning("Attempt %d: Failed to copy executable to %s (Error: %d). Retrying..." % [attempt + 1, original_path, copy_err])
				OS.delay_msec(500)
		
		if not success:
			AppLogger.error("Critical: Failed to overwrite original executable after 5 attempts.")

		# Update the companion .pck file with retry protection as well
		var current_pck = current_exe.get_basename() + ".pck"
		var original_pck = original_path.get_basename() + ".pck"
		
		if FileAccess.file_exists(current_pck):
			for attempt in range(5):
				if FileAccess.file_exists(original_pck):
					DirAccess.remove_absolute(original_pck)
				var pck_copy_err = DirAccess.copy_absolute(current_pck, original_pck)
				if pck_copy_err == OK:
					AppLogger.info("Successfully updated companion .pck file.")
					break
				else:
					OS.delay_msec(300)

		if OS.has_feature("linux") or OS.has_feature("macos") or OS.has_feature("bsd"):
			FileAccess.set_unix_permissions(original_path, 493)

		AppLogger.info("Launching updated application...")
		OS.create_process(original_path, [])
	get_tree().quit()


# --- Shared Network & API Helpers ---

func _fetch_github_release(repo: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		if response_code == 403 or response_code == 429:
			AppLogger.error("API Rate Limit Exceeded (403/429) on: " + repo)
			_show_rate_limit_popup()
			callback.call({})
			return
			
		if response_code != 200:
			AppLogger.error("API Error on " + repo + " - Code: " + str(response_code))
			callback.call({})
			return
			
		var json = JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
			callback.call(json.data)
		else:
			callback.call({})
	)
	
	var headers = ["User-Agent: SeveredChains-Launcher"]
	var token = _get_github_token()
	
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
			
	http.request(AppConfig.GITHUB_API_URL + repo + "/releases/latest", headers)

func _download_asset(url: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		if response_code == 200:
			callback.call(body)
		else:
			AppLogger.error("HTTP Download failed. Code: " + str(response_code) + " URL: " + url)
			callback.call(PackedByteArray()) 
	)
	
	var err = http.request(url, ["User-Agent: SeveredChains-Launcher"])
	if err != OK:
		AppLogger.error("Failed to initialize HTTP request for asset download.")
		http.queue_free()
		callback.call(PackedByteArray())

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

func _get_github_token() -> String:
	var token_path = base_dir.path_join(AppConfig.TOKEN_PATH)
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		return token_file.get_as_text().strip_edges()
	return ""


# --- GitHub Changelog Pipeline ---

func _fetch_changelog() -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(_on_changelog_request_completed)
	
	var url = AppConfig.GITHUB_API_URL + AppConfig.ENGINE_REPO + "/commits?sha=main"
	var headers = ["User-Agent: SeveredChains-Launcher"]
	
	var token = _get_github_token()
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
			
	http.request(url, headers)

func _on_changelog_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var http_node = get_node_or_null("HTTPRequest") 
	if http_node: 
		http_node.queue_free()
		
	if response_code != 200:
		AppLogger.error("Changelog fetch failed. HTTP Code: " + str(response_code))
		return
		
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK and json.data is Array:
		_populate_changelog_ui(json.data.slice(0, 30))
	else:
		AppLogger.error("Failed to parse changelog JSON response.")

func _populate_changelog_ui(commits: Array) -> void:
	for commit_data in commits:
		var parsed_data = _parse_commit_data(commit_data)
		_spawn_changelog_item(
			parsed_data["title"], 
			parsed_data["url"], 
			parsed_data["date"], 
			parsed_data["description"]
		)

func _parse_commit_data(commit_data: Dictionary) -> Dictionary:
	var commit_info = commit_data.get("commit", {})
	var message = commit_info.get("message", "No description provided.")
	var date = commit_info.get("author", {}).get("date", "").replace("T", " ").replace("Z", "")
	var url = commit_data.get("html_url", "")
	
	var github_user = commit_data.get("author")
	var author = github_user.get("login", "Unknown Developer") if github_user else commit_info.get("author", {}).get("name", "Unknown Developer")
	
	var split_msg = message.split("\n")
	var title = split_msg[0]
	var description = _extract_commit_description(split_msg, author)
	
	return {
		"title": title,
		"url": url,
		"date": date,
		"description": description
	}

func _extract_commit_description(message_lines: PackedStringArray, author: String) -> String:
	if message_lines.size() <= 1:
		return "Committed by " + author
		
	var desc_lines = PackedStringArray()
	for i in range(1, message_lines.size()):
		var line = message_lines[i].strip_edges()
		if not line.begins_with("Co-authored-by:"):
			desc_lines.append(line)
			
	return "\n".join(desc_lines).strip_edges()


# --- RSS Feed Pipeline ---

func _load_rss_feed() -> void:
	var loading_label = Label.new()
	loading_label.name = "LoadingLabel"
	loading_label.text = "Loading news..."
	news_container.add_child(loading_label)

	if not rss_http.request_completed.is_connected(_on_rss_completed):
		rss_http.request_completed.connect(_on_rss_completed)
		
	rss_http.request(AppConfig.RSS_FEED_URL, ["User-Agent: SeveredChains-Launcher"])

func _on_rss_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var loading_node = news_container.get_node_or_null("LoadingLabel")
	if loading_node:
		loading_node.queue_free()

	if response_code != 200:
		AppLogger.error("Failed to fetch RSS. Status: " + str(response_code))
		return

	_parse_rss_xml(body)

func _parse_rss_xml(body: PackedByteArray) -> void:
	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK:
		AppLogger.error("Failed to open RSS XML buffer.")
		return

	var in_item = false
	var current_title = ""
	var current_link = ""
	var current_date = ""
	var current_desc = ""
	var current_node = ""

	while parser.read() == OK:
		var node_type = parser.get_node_type()
		
		if node_type == XMLParser.NODE_ELEMENT:
			current_node = parser.get_node_name().to_lower()
			if current_node == "item":
				in_item = true
				
		elif (node_type == XMLParser.NODE_TEXT or node_type == XMLParser.NODE_CDATA) and in_item:
			var text = parser.get_node_data().strip_edges() if node_type == XMLParser.NODE_TEXT else parser.get_node_name().strip_edges()
			
			if text != "":
				match current_node:
					"title": current_title += text
					"link": current_link += text
					"pubdate": current_date += text
					"description", "content:encoded": current_desc += text
					
		elif node_type == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name().to_lower() == "item":
				in_item = false
				
				var clean_desc = _sanitize_html(current_desc)
				var clean_date = _format_pubdate(current_date)
				
				_spawn_rss_item(current_title, current_link, clean_date, clean_desc)
				
				current_title = ""
				current_link = ""
				current_date = ""
				current_desc = ""

func _sanitize_html(raw_html: String) -> String:
	var regex = RegEx.new()
	regex.compile("<[^>]*>")
	
	var clean_desc = regex.sub(raw_html, "", true).strip_edges().xml_unescape()
	if clean_desc.length() > 200:
		clean_desc = clean_desc.substr(0, 197) + "..."
		
	return clean_desc

func _format_pubdate(raw_date: String) -> String:
	var date_parts = raw_date.split(" ", false)
	if date_parts.size() >= 4:
		return "%s %s %s %s" % [date_parts[0], date_parts[1], date_parts[2], date_parts[3]]
	return raw_date


# --- UI Spawners ---

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


# --- Token UI Logic ---

func _setup_token_dialog() -> void:
	token_dialog = ConfirmationDialog.new()
	token_dialog.title = "Add GitHub API Token"
	token_dialog.ok_button_text = "Save"
	token_dialog.cancel_button_text = "Cancel"
	token_dialog.min_size = Vector2(400, 110)
	
	var vbox = VBoxContainer.new()
	var label = Label.new()
	label.text = "Paste your GitHub Personal Access Token to prevent API rate limits:"
	vbox.add_child(label)
	
	token_input = LineEdit.new()
	token_input.secret = true 
	token_input.placeholder_text = "ghp_..."
	vbox.add_child(token_input)
	
	token_dialog.add_child(vbox)
	add_child(token_dialog)
	
	token_dialog.confirmed.connect(_on_token_saved)
	token_dialog.canceled.connect(func(): token_input.text = "")

func _on_add_token_btn_pressed() -> void:
	token_input.text = ""
	token_dialog.popup_centered()

func _on_token_saved() -> void:
	var token = token_input.text.strip_edges()
	if not token.is_empty():
		var token_path = base_dir.path_join(AppConfig.TOKEN_PATH)
		DirAccess.make_dir_recursive_absolute(token_path.get_base_dir())
		
		var file = FileAccess.open(token_path, FileAccess.WRITE)
		if file:
			file.store_string(token)
			file.close()
			AppLogger.info("GitHub API token saved successfully.")
		else:
			AppLogger.error("Failed to write GitHub API token to: " + token_path)
			
		_update_token_button_state()

func _update_token_button_state() -> void:
	if not _get_github_token().is_empty():
		add_token_btn.text = "Token Found"
		add_token_btn.disabled = true
	else:
		add_token_btn.text = "Add API Token"
		add_token_btn.disabled = false


func _setup_update_dialog() -> void:
	update_progress_dialog = AcceptDialog.new()
	update_progress_dialog.title = "Launcher Update"
	update_progress_dialog.dialog_text = "Downloading update..."
	update_progress_dialog.exclusive = true 
	add_child(update_progress_dialog)
	
	var ok_btn = update_progress_dialog.get_ok_button()
	if ok_btn:
		ok_btn.hide()


# --- Severed Chains Rebuild ---
func _purge_game_installation() -> void:
	if not DirAccess.dir_exists_absolute(active_sc_dir): 
		AppLogger.warning("Purge aborted: Target directory does not exist (" + active_sc_dir + ")")
		return
	
	var safe_folders = ["isos", "mods", "saves"]
	var dir = DirAccess.open(active_sc_dir)
	if not dir: 
		AppLogger.error("Failed to open directory for purging: " + active_sc_dir)
		return
	
	AppLogger.info("Starting purge of game installation directory: " + active_sc_dir)
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			if dir.current_is_dir() and file_name in safe_folders:
				pass # Keep it safe
			else:
				var target_path = active_sc_dir.path_join(file_name)
				if dir.current_is_dir():
					FileUtiles.remove_dir_recursive(target_path)
				else:
					DirAccess.remove_absolute(target_path)
					
		file_name = dir.get_next()
		
	AppLogger.info("Game installation purge complete.")
	_check_engine_installed()


# --- Helper Functions ---
var _rate_limit_popup_active: bool = false
func _show_rate_limit_popup() -> void:
	if _rate_limit_popup_active: return
	_rate_limit_popup_active = true
	
	var dialog = AcceptDialog.new()
	dialog.title = "GitHub API Limit Exceeded"
	dialog.dialog_text = "You have exceeded GitHub's hourly request limit.\n\nPlease wait up to an hour.\n\nor add a GitHub Personal Access Token in the Misc tab to permanently bypass this limit."
	
	add_child(dialog)
	dialog.popup_centered()
	
	dialog.confirmed.connect(func(): 
		_rate_limit_popup_active = false
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): 
		_rate_limit_popup_active = false
		dialog.queue_free()
	)

func _show_crash_popup(error_msg: String, log_path: String = "") -> void:
	var dialog = AcceptDialog.new()
	dialog.title = "Game Launch Failed"
	
	var vbox = VBoxContainer.new()
	
	if not log_path.is_empty():
		var path_label = Label.new()
		path_label.text = "Log saved to: " + log_path
		path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(path_label)
		
	var text_edit = TextEdit.new()
	text_edit.text = error_msg
	text_edit.editable = false
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text_edit.custom_minimum_size = Vector2(600, 250)
	vbox.add_child(text_edit)
	
	dialog.add_child(vbox)
	dialog.min_size = Vector2(650, 350)
	
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func(): dialog.queue_free())

# --- Delete eventually ---
func _migrate_legacy_installation() -> void:
	if OS.has_feature("editor"):
		return
		
	var legacy_bat = base_dir.path_join("launch.bat")
	var legacy_sh = base_dir.path_join("launch")
	
	if not FileAccess.file_exists(legacy_bat) and not FileAccess.file_exists(legacy_sh):
		return 
		
	AppLogger.info("Migrating legacy Severed Chains installation to new structure...")
	DirAccess.make_dir_recursive_absolute(active_sc_dir)
	
	var dir = DirAccess.open(base_dir)
	if not dir: 
		AppLogger.error("Migration failed: Cannot open base directory.")
		return
	
	var exclusions = [
		".", "..", 
		AppConfig.MOD_DATA_DIR, 
		AppConfig.SC_STABLE_DIR
	]
	
	dir.list_dir_begin()
	var item_name = dir.get_next()
	
	while item_name != "":
		var is_launcher_binary = item_name.begins_with("severed-chains-launcher")
		
		if not (item_name in exclusions) and not is_launcher_binary:
			var src = base_dir.path_join(item_name)
			var dst = active_sc_dir.path_join(item_name)
			
			DirAccess.rename_absolute(src, dst)
			
		item_name = dir.get_next()
