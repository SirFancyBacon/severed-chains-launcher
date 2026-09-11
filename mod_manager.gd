extends Control
class_name ModManagerUI

const MOD_ROW_SCENE = preload("res://resources/mod_row.tscn")

# Renamed to match the new architecture
@onready var state_manager: ModStateManager = $ModStateManager
@onready var repo_input: LineEdit = $MarginContainer/MainVBox/HeaderHBox/CustomRepoInput
@onready var add_repo_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddRepoButton
@onready var fetch_button: Button = $MarginContainer/MainVBox/HeaderHBox/FetchButton
@onready var add_local_btn: Button = $MarginContainer/MainVBox/HeaderHBox/AddLocalButton
@onready var status_label: Label = $MarginContainer/MainVBox/StatusLabel
@onready var mod_list_container: VBoxContainer = $MarginContainer/MainVBox/ModListScroll/ModList

var conflict_dialog: ConfirmationDialog
var _current_confirm: Callable
var _current_cancel: Callable

func initialize_paths(root_dir: String) -> void:
	_setup_conflict_dialog()
	_connect_service_signals()
	
	# Mapped to the new State Manager functions
	fetch_button.pressed.connect(state_manager.refresh_mod_list)
	add_repo_btn.pressed.connect(_on_add_repo_btn_pressed)
	
	# We will re-wire local ZIP installs in the final phase
	# add_local_btn.pressed.connect(state_manager.prompt_local_zip) 
	
	state_manager.initialize_paths(root_dir)
	state_manager.refresh_mod_list()

func _setup_conflict_dialog() -> void:
	conflict_dialog = ConfirmationDialog.new()
	conflict_dialog.title = "File Overwrite Conflict"
	conflict_dialog.ok_button_text = "Overwrite"
	conflict_dialog.cancel_button_text = "Cancel"
	
	# Ensures it looks consistent with the rest of your 960x540 launcher
	conflict_dialog.min_size = Vector2(350, 120) 
	add_child(conflict_dialog)

func _connect_service_signals() -> void:
	state_manager.status_updated.connect(func(msg): status_label.text = msg)
	state_manager.mod_lists_merged.connect(_on_mod_lists_merged)
	state_manager.remote_info_updated.connect(_on_remote_info_updated)
	
	# New installation and conflict signals
	state_manager.conflict_detected.connect(_on_conflict_detected)
	state_manager.install_completed.connect(_on_install_completed)
	
	# Network progress is passed straight through from the decoupled Networker
	state_manager.networker.download_progress.connect(_on_download_progress)


# --- Core UI Interactions ---

func _on_add_repo_btn_pressed() -> void:
	state_manager.add_custom_repo(repo_input.text.strip_edges())
	repo_input.text = ""

func _on_mod_lists_merged(merged_list: Array, installed_data: Dictionary) -> void:
	for child in mod_list_container.get_children():
		child.queue_free()
		
	for repo in merged_list:
		var mod_data = installed_data.get(repo, {})
		var cur_version = mod_data.get("version", "")
		var is_enabled = mod_data.get("enabled", false)
		_spawn_mod_row(repo, cur_version, is_enabled)

func _spawn_mod_row(repo: String, current_version: String, is_enabled: bool) -> void:
	var row = MOD_ROW_SCENE.instantiate()
	mod_list_container.add_child(row)
	row.setup(repo, current_version, is_enabled)
	
	row.update_requested.connect(func(r, url, version): state_manager.begin_installation(r, url, version))
	
	# We will port these two functions over to ModStateManager in the final step
	row.enable_toggled.connect(func(r, enabled): state_manager.toggle_mod_enabled(r, enabled))
	row.uninstall_requested.connect(func(r): state_manager.uninstall_mod(r))

func _get_row(repo: String) -> Control:
	for row in mod_list_container.get_children():
		if row.repo_id == repo:
			return row
	return null


# --- Remote Info & Progress Updates ---

func _on_remote_info_updated(repo: String, tag: String, download_url: String, current_version: String) -> void:
	var row = _get_row(repo)
	if row:
		row.set_remote_info(tag, download_url, current_version)

func _on_download_progress(repo: String, current: int, total: int) -> void:
	var row = _get_row(repo)
	if row and row.has_method("update_progress"):
		row.update_progress(current, total)


# --- Conflict Resolution Pipeline ---

func _on_conflict_detected(repo: String, conflicts: Array, temp_dir: String) -> void:
	var row = _get_row(repo)
	if row: row.install_progress.max_value = 0 # Trigger the indeterminate bounce effect
	
	var version = row.latest_version if row else "Unknown"
	
	# Clear out any stale button connections from previous mods
	if _current_confirm.is_valid():
		conflict_dialog.confirmed.disconnect(_current_confirm)
		conflict_dialog.canceled.disconnect(_current_cancel)
		
	# Assign the new resolutions
	_current_confirm = func(): state_manager.resolve_installation(repo, version, temp_dir, true)
	_current_cancel = func(): state_manager.resolve_installation(repo, version, temp_dir, false)
	
	conflict_dialog.confirmed.connect(_current_confirm)
	conflict_dialog.canceled.connect(_current_cancel)
	
	# Warn the user how many files are colliding
	conflict_dialog.dialog_text = "Mod '%s' will overwrite %d existing game files.\n\nContinue?" % [repo.split("/")[1], conflicts.size()]
	conflict_dialog.popup_centered()

func _on_install_completed(repo: String, success: bool) -> void:
	var row = _get_row(repo)
	if row:
		row.install_progress.visible = false
		if success:
			row.set_remote_info(row.latest_version, row.asset_download_url, row.latest_version)
			row.enable_check.button_pressed = true
			row.enable_check.disabled = false
