extends PanelContainer

signal enable_toggled(repo: String, is_enabled: bool)
signal update_requested(repo: String, asset_url: String, new_version: String)
signal uninstall_requested(repo: String)

@onready var name_label: LinkButton = $MarginContainer/HBoxContainer/ModNameLabel
@onready var version_label: Label = $MarginContainer/HBoxContainer/VersionLabel
@onready var status_label: Label = $MarginContainer/HBoxContainer/StatusLabel
@onready var enable_check: CheckButton = $MarginContainer/HBoxContainer/EnableCheck
@onready var update_btn: Button = $MarginContainer/HBoxContainer/UpdateButton
@onready var uninstall_btn: Button =$MarginContainer/HBoxContainer/UninstallButton
@onready var install_progress: ProgressBar = $MarginContainer/HBoxContainer/InstallProgress

var repo_id: String = ""
var latest_version: String = ""
var asset_download_url: String = ""

func _ready() -> void:
	name_label.pressed.connect(func(): OS.shell_open("https://github.com/" + repo_id))
	enable_check.toggled.connect(_on_enable_check_toggled)
	update_btn.pressed.connect(_on_update_button_pressed)
	uninstall_btn.pressed.connect(_on_uninstall_button_pressed)

func setup(repo: String, current_version: String, is_enabled: bool, display_name: String = "", description: String = "") -> void:
	repo_id = repo
	
	if not display_name.is_empty():
		name_label.text = display_name
	else:
		var parts = repo.split("/")
		name_label.text = parts[1] if parts.size() > 1 else repo
	
	# Apply the description tooltip
	if not description.is_empty():
		name_label.tooltip_text = _format_tooltip(description, 60)
	else:
		name_label.tooltip_text = "No description provided."
	
	version_label.text = current_version if current_version != "" else "N/A"
	enable_check.button_pressed = is_enabled
	enable_check.disabled = (current_version == "")
	update_btn.visible = false
	install_progress.visible = false
	uninstall_btn.visible = false
	status_label.text = "Checking..."


func _format_tooltip(text: String, max_line_length: int) -> String:
	# Convert escaped JSON newlines into actual Godot newlines
	var clean_text = text.replace("\\n", "\n")
	var lines = clean_text.split("\n")
	var final_text = ""
	
	for line in lines:
		var words = line.split(" ")
		var current_line = ""
		
		for word in words:
			if current_line.length() + word.length() > max_line_length:
				final_text += current_line.strip_edges() + "\n"
				current_line = ""
			current_line += word + " "
		
		final_text += current_line.strip_edges() + "\n"
		
	return final_text.strip_edges()


func set_remote_info(tag: String, download_url: String, installed_version: String) -> void:
	install_progress.visible = false
	latest_version = tag
	asset_download_url = download_url
	version_label.text = installed_version if installed_version != "" else "N/A"
	
	uninstall_btn.visible = (installed_version != "")
	
	if installed_version == "":
		status_label.text = "[Not Installed]"
		update_btn.text = "Download"
		update_btn.visible = true
	elif installed_version != tag:
		status_label.text = "[Update: " + tag + "]"
		update_btn.text = "Update"
		update_btn.visible = true
	else:
		status_label.text = "[Up to Date]"
		update_btn.visible = false
	
	enable_check.disabled = (installed_version == "")

func _on_enable_check_toggled(button_pressed: bool) -> void:
	enable_toggled.emit(repo_id, button_pressed)

func _on_update_button_pressed() -> void:
	update_btn.visible = false
	install_progress.visible = true
	install_progress.value = 0 # Reset just in case
	update_requested.emit(repo_id, asset_download_url, latest_version)

func _on_uninstall_button_pressed() -> void:
	uninstall_requested.emit(repo_id)

func update_progress(current_bytes: int, total_bytes: int) -> void:
	if install_progress:
		install_progress.max_value = total_bytes
		install_progress.value = current_bytes
