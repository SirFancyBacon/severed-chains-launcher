extends Control

var base_dir: String = ""
var rss_url: String = "https://legendofdragoon.org/feed/" 


@onready var version_label: Label = $MarginContainer/MainHBox/LeftColumn/HeaderTitles/SubtitleLabel
@onready var rss_http: HTTPRequest = $RSSRequest
@onready var news_container: VBoxContainer = $MarginContainer/MainHBox/LeftColumn/TabContainer/News/ScrollContainer/RSSFeedList
@onready var launch_button: Button = $MarginContainer/MainHBox/RightColumn/LaunchButton
@onready var discord_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/DiscordButton
@onready var github_button: TextureButton = $MarginContainer/MainHBox/RightColumn/SocialsHBox/GithubButton
@onready var mod_manager: Control = $"MarginContainer/MainHBox/LeftColumn/TabContainer/Mod Manager/ModManager"



func _ready() -> void:
	var app_version = ProjectSettings.get_setting("application/config/version", "1.0.0")
	version_label.text = "Version:: " + app_version
	if OS.has_feature("editor"):
		base_dir = ProjectSettings.globalize_path("res://")
	else:
		base_dir = OS.get_executable_path().get_base_dir()
		
	mod_manager.initialize_paths(base_dir)
		
	launch_button.pressed.connect(_on_launch_button_pressed)
	rss_http.request_completed.connect(_on_rss_request_completed)
	
	# Spawn the temporary loading label
	var loading_label = Label.new()
	loading_label.name = "LoadingLabel"
	loading_label.text = "Loading news..."
	news_container.add_child(loading_label)
	
	var headers = ["User-Agent: SeveredChains-Launcher"]
	rss_http.request(rss_url, headers)
	discord_button.pressed.connect(func(): OS.shell_open("https://discord.gg/rQWXgK5"))
	github_button.pressed.connect(func(): OS.shell_open("https://github.com/Legend-of-Dragoon-Modding/Severed-Chains"))

# --- Launch Logic ---

func _on_launch_button_pressed() -> void:
	var pid: int = -1
	
	if OS.has_feature("windows"):
		var script_path = base_dir.path_join("launch.bat")
		if FileAccess.file_exists(script_path):
			# Run via cmd.exe, changing drive and directory first to ensure relative paths resolve
			var command = "/c cd /d \"%s\" && start \"\" \"launch.bat\"" % base_dir
			pid = OS.create_process("cmd.exe", ["/c", "cd", "/d", base_dir, "&&", "launch.bat"])
		else:
			print("launch.bat not found at: ", script_path)
			
	elif OS.has_feature("linux") or OS.has_feature("macos") or OS.has_feature("bsd"):
		var script_path = base_dir.path_join("launch")
		if FileAccess.file_exists(script_path):
			# Ensure the script has execute permissions before spawning
			OS.execute("chmod", ["+x", script_path])
			
			# Spawn bash directly to execute the script in a detached process
			pid = OS.create_process("/bin/bash", [script_path])
		else:
			print("launch script not found at: ", script_path)

	if pid > 0:
		print("Game launched successfully with PID: ", pid)
		# Optional: close launcher when game starts
		# get_tree().quit()
	elif pid == -1:
		print("Failed to launch game process.")

# --- RSS Parsing Logic ---

func _on_rss_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code == 200:
		parse_rss(body)
	else:
		print("Failed to fetch RSS. Status: ", response_code)

func parse_rss(body: PackedByteArray) -> void:
	# Find and delete the loading label if it exists
	var loading_node = news_container.get_node_or_null("LoadingLabel")
	if loading_node:
		loading_node.queue_free()

	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK:
		print("Failed to open RSS buffer.")
		return
		
	var in_item := false
	var current_title := ""
	var current_link := ""
	var current_node := ""
	
	# Loop through the XML tags
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			var node_name = parser.get_node_name().to_lower()
			if node_name == "item":
				in_item = true
			current_node = node_name
			
		elif parser.get_node_type() == XMLParser.NODE_TEXT and in_item:
			var text = parser.get_node_data().strip_edges()
			if text == "": continue
			
			if current_node == "title":
				current_title = text
			elif current_node == "link":
				current_link = text
				
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
	
	# Add this line so the label fills the width of the container
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	label.meta_clicked.connect(func(meta_link): OS.shell_open(str(meta_link)))
	
	news_container.add_child(label)
