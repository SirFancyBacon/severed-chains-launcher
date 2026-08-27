extends Control

var base_dir: String = ""
var rss_url: String = "https://legendofdragoon.org/feed/" 
var ready_update_path: String = ""

@onready var version_label: Label = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/HeaderTitles/SubtitleLabel
@onready var launcher_update_btn: Button = $MarginContainer/MainHBox/LeftColumn/HeaderHBox/LauncherUpdateButton
@onready var rss_http: HTTPRequest = $RSSRequest
@onready var news_container: VBoxContainer = $MarginContainer/MainHBox/LeftColumn/TabContainer/News/ScrollContainer/RSSFeedList
@onready var launch_button: Button = $MarginContainer/MainHBox/RightColumn/LaunchButton
@onready var discord_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/DiscordButton
@onready var github_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/GithubButton
@onready var mod_manager: Control = $"MarginContainer/MainHBox/LeftColumn/TabContainer/Mod Manager/ModManager"

func _ready() -> void:
	launcher_update_btn.visible = false
	launcher_update_btn.pressed.connect(_on_launcher_update_btn_pressed)

	# 1. BULLETPROOF ARGUMENT INTERCEPTION
	var args = OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--apply-update" and args.size() > i + 2:
			apply_update_and_restart(args[i+1].to_int(), args[i+2])
			return 
		
	var app_version = ProjectSettings.get_setting("application/config/version", "1.0.0")
	version_label.text = "Version:: " + app_version
	
	if OS.has_feature("editor"):
		base_dir = ProjectSettings.globalize_path("res://")
	else:
		base_dir = OS.get_executable_path().get_base_dir()
		check_for_launcher_updates()
		
	mod_manager.initialize_paths(base_dir)
		
	launch_button.pressed.connect(_on_launch_button_pressed)
	rss_http.request_completed.connect(_on_rss_request_completed)
	
	var loading_label = Label.new()
	loading_label.name = "LoadingLabel"
	loading_label.text = "Loading news..."
	news_container.add_child(loading_label)
	
	var headers = ["User-Agent: SeveredChains-Launcher"]
	rss_http.request(rss_url, headers)
	discord_button.pressed.connect(func(): OS.shell_open("https://discord.gg/rQWXgK5"))
	github_button.pressed.connect(func(): OS.shell_open("https://github.com/Legend-of-Dragoon-Modding/Severed-Chains"))

# --- Launcher Self-Updater Logic ---

func _on_launcher_update_btn_pressed() -> void:
	if OS.has_feature("linux") or OS.has_feature("macos"):
		# 493 is the decimal equivalent of octal 755 (rwxr-xr-x)
		FileAccess.set_unix_permissions(ready_update_path, 493) 
		
	var pid = OS.create_process(ready_update_path, ["--apply-update", str(OS.get_process_id()), OS.get_executable_path()])
	
	if pid == -1:
		launcher_update_btn.text = "Error: OS Blocked Launch"
	else:
		get_tree().quit()

func apply_update_and_restart(target_pid: int, original_path: String) -> void:
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
			# 493 is the decimal equivalent of octal 755 (rwxr-xr-x)
			FileAccess.set_unix_permissions(original_path, 493) 

		OS.create_process(original_path, [])
		
	get_tree().quit()

func check_for_launcher_updates() -> void:
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_updater_api_completed.bind(http))
	http.request("https://api.github.com/repos/sirfancybacon/severed-chains-launcher/releases/latest", ["User-Agent: SeveredChains-Launcher"])

func _on_updater_api_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if response_code != 200: return

	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK: return

	var data = json.data
	var latest_version = data.get("tag_name", "").trim_prefix("v")
	var current_version = ProjectSettings.get_setting("application/config/version", "1.0.0").trim_prefix("v")

	if latest_version != "" and latest_version != current_version:
		var target_asset_url = ""
		for asset in data.get("assets", []):
			var asset_name = asset.get("name", "").to_lower()
			if OS.has_feature("windows") and "win" in asset_name:
				target_asset_url = asset.get("browser_download_url", "")
			elif OS.has_feature("linux") and "linux" in asset_name:
				target_asset_url = asset.get("browser_download_url", "")
			elif OS.has_feature("macos") and "mac" in asset_name:
				target_asset_url = asset.get("browser_download_url", "")

		if target_asset_url != "":
			var dl_http = HTTPRequest.new()
			add_child(dl_http)
			dl_http.request_completed.connect(_on_updater_download_completed.bind(dl_http, latest_version))
			dl_http.request(target_asset_url, ["User-Agent: SeveredChains-Launcher"])

func _on_updater_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, target_version: String) -> void:
	http.queue_free()
	if response_code == 200:
		ModExtractor.begin_updater_extraction(body, target_version, base_dir.path_join("mod_manager_data"), _trigger_handoff)

func _trigger_handoff(repo: String, version: String, items: Array, message: String, success: bool) -> void:
	if not success: return

	var update_dir = base_dir.path_join("mod_manager_data/updater")
	var dir = DirAccess.open(update_dir)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.get_extension() != "pck" and file_name.get_extension() != "zip":
				# Windows safety net to ensure we grab the executable
				if OS.has_feature("windows") and file_name.get_extension() != "exe":
					file_name = dir.get_next()
					continue
					
				ready_update_path = update_dir.path_join(file_name)
				break
			file_name = dir.get_next()
			
	if ready_update_path != "":
		launcher_update_btn.text = "Update v" + version + " Ready!"
		launcher_update_btn.visible = true

# --- Launch Logic ---

func _on_launch_button_pressed() -> void:
	var pid: int = -1
	
	if OS.has_feature("windows"):
		var script_path = base_dir.path_join("launch.bat")
		if FileAccess.file_exists(script_path):
			pid = OS.create_process("cmd.exe", ["/c", "cd", "/d", base_dir, "&&", "launch.bat"])
		else:
			print("launch.bat not found at: ", script_path)
			
	elif OS.has_feature("linux") or OS.has_feature("macos") or OS.has_feature("bsd"):
		var script_path = base_dir.path_join("launch")
		if FileAccess.file_exists(script_path):
			OS.execute("chmod", ["+x", script_path])
			pid = OS.create_process("/bin/bash", [script_path])
		else:
			print("launch script not found at: ", script_path)

	if pid > 0:
		print("Game launched successfully with PID: ", pid)
	elif pid == -1:
		print("Failed to launch game process.")

# --- RSS Parsing Logic ---

func _on_rss_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 200:
		parse_rss(body)
	else:
		print("Failed to fetch RSS. Status: ", response_code)

func parse_rss(body: PackedByteArray) -> void:
	var loading_node = news_container.get_node_or_null("LoadingLabel")
	if loading_node:
		loading_node.queue_free()

	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK: return
		
	var in_item := false
	var current_title := ""
	var current_link := ""
	var current_node := ""
	
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			var node_name = parser.get_node_name().to_lower()
			if node_name == "item": in_item = true
			current_node = node_name
			
		elif parser.get_node_type() == XMLParser.NODE_TEXT and in_item:
			var text = parser.get_node_data().strip_edges()
			if text == "": continue
			
			if current_node == "title": current_title = text
			elif current_node == "link": current_link = text
				
		elif parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
			var node_name = parser.get_node_name().to_lower()
			if node_name == "item":
				in_item = false
				spawn_news_item(current_title, current_link)
				current_title = ""
				current_link = ""

func spawn_news_item(title: String, link: String) -> void:
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = "[url=" + link + "]- " + title + "[/url]"
	label.fit_content = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.meta_clicked.connect(func(meta_link): OS.shell_open(str(meta_link)))
	news_container.add_child(label)
