extends Control
class_name ModManagerUI

const MOD_ROW_SCENE = preload("res://resources/ModRow.tscn")

@onready var mod_service: ModService = $ModService
@onready var repo_input: LineEdit = $MarginContainer/MainVBox/HeaderHBox/CustomRepoInput
@onready var add_repo_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddRepoButton
@onready var fetch_button: Button = $MarginContainer/MainVBox/HeaderHBox/FetchButton
@onready var add_local_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddLocalButton
@onready var status_label: Label = $MarginContainer/MainVBox/StatusLabel
@onready var mod_list_container: VBoxContainer = $MarginContainer/MainVBox/ModListScroll/ModList

func initialize_paths(root_dir: String) -> void:
	_connect_service_signals()
	
	fetch_button.pressed.connect(mod_service.start_fetch)
	add_local_btn.pressed.connect(mod_service.prompt_local_zip)
	add_repo_btn.pressed.connect(_on_add_repo_btn_pressed)
	
	mod_service.initialize_paths(root_dir)
	mod_service.start_fetch()

func _connect_service_signals() -> void:
	mod_service.status_updated.connect(func(msg): status_label.text = msg)
	mod_service.mod_list_ready.connect(_on_mod_list_ready)
	mod_service.mod_added.connect(_on_mod_added)
	mod_service.mod_remote_info_updated.connect(_on_mod_remote_info_updated)
	mod_service.mod_api_error.connect(_on_mod_api_error)
	mod_service.download_progress.connect(_on_download_progress)
	mod_service.extraction_started.connect(_on_extraction_started)
	mod_service.mod_uninstalled.connect(_on_mod_uninstalled)

func _on_add_repo_btn_pressed() -> void:
	mod_service.add_custom_repo(repo_input.text.strip_edges())
	repo_input.text = ""

func _on_mod_list_ready(mod_list: Array, installed_data: Dictionary) -> void:
	for child in mod_list_container.get_children():
		child.queue_free()
		
	for repo in mod_list:
		var mod_data = installed_data.get(repo, {})
		var cur_version = mod_data.get("version", "")
		var is_enabled = mod_data.get("enabled", false)
		_spawn_mod_row(repo, cur_version, is_enabled)

func _on_mod_added(repo: String, current_version: String, is_enabled: bool) -> void:
	_spawn_mod_row(repo, current_version, is_enabled)

func _spawn_mod_row(repo: String, current_version: String, is_enabled: bool) -> void:
	var row = MOD_ROW_SCENE.instantiate()
	mod_list_container.add_child(row)
	row.setup(repo, current_version, is_enabled)
	
	row.enable_toggled.connect(mod_service.toggle_mod_enabled)
	row.update_requested.connect(mod_service.queue_download)
	row.uninstall_requested.connect(mod_service.uninstall_mod)

func _get_row(repo: String) -> Control:
	for row in mod_list_container.get_children():
		if row.repo_id == repo:
			return row
	return null

func _on_mod_remote_info_updated(repo: String, tag: String, download_url: String, current_version: String) -> void:
	var row = _get_row(repo)
	if row:
		row.set_remote_info(tag, download_url, current_version)

func _on_mod_api_error(repo: String, current_version: String, is_rate_limited: bool) -> void:
	var row = _get_row(repo)
	if row:
		row.version_label.text = current_version if current_version != "" else "N/A"
		row.enable_check.disabled = (current_version == "")
		row.status_label.text = "[API Rate Limited]" if is_rate_limited else "[API Error]"
		if current_version != "" and "uninstall_btn" in row:
			row.uninstall_btn.visible = true

func _on_download_progress(repo: String, current: int, total: int) -> void:
	var row = _get_row(repo)
	if row and row.has_method("update_progress"):
		row.update_progress(current, total)

func _on_extraction_started(repo: String) -> void:
	var row = _get_row(repo)
	if row and row.has_method("update_progress"):
		row.install_progress.max_value = 0 # Indeterminate bounce

func _on_mod_uninstalled(repo: String) -> void:
	var row = _get_row(repo)
	if row:
		if repo.begins_with("local/"):
			row.queue_free() 
		else:
			row.set_remote_info(row.latest_version, row.asset_download_url, "")
			row.enable_check.button_pressed = false
