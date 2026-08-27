extends PanelContainer

signal enable_toggled(repo: String, is_enabled: bool)
signal update_requested(repo: String, asset_url: String, new_version: String)
signal uninstall_requested(repo: String)

@onready var name_label: Label = $MarginContainer/HBoxContainer/ModNameLabel
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
	# Wire up the UI interactions to our local functions
	enable_check.toggled.connect(_on_enable_check_toggled)
	update_btn.pressed.connect(_on_update_button_pressed)
	uninstall_btn.pressed.connect(_on_uninstall_button_pressed)

func setup(repo: String, current_version: String, is_enabled: bool) -> void:
	repo_id = repo
	name_label.text = repo.split("/")[1]
	version_label.text = current_version if current_version != "" else "N/A"
	enable_check.button_pressed = is_enabled
	enable_check.disabled = (current_version == "")
	update_btn.visible = false
	install_progress.visible = false
	uninstall_btn.visible = false
	status_label.text = "Checking..."

func set_remote_info(tag: String, download_url: String, installed_version: String) -> void:
	install_progress.visible = false
	latest_version = tag
	asset_download_url = download_url
	version_label.text = installed_version if installed_version != "" else "N/A"
	
	uninstall_btn.visible = (installed_version != "")
	
	if installed_version == "":
		status_label.text = "[Not Installed]"
		update_btn.text = "Install"
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
