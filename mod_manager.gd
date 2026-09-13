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
@onready var local_zip_dialog: FileDialog = $LocalZipFileDialog
@onready var upgrade_all_btn: Button = $MarginContainer/MainVBox/HeaderHBox/UpdateButton

var conflict_dialog: ConfirmationDialog
var _current_confirm: Callable
var _current_cancel: Callable

func initialize_paths(root_dir: String) -> void:
	_setup_conflict_dialog()
	_connect_service_signals()
	
	# Mapped to the new State Manager functions
	fetch_button.pressed.connect(state_manager.refresh_mod_list)
	add_repo_btn.pressed.connect(_on_add_repo_btn_pressed)
	upgrade_all_btn.pressed.connect(_on_upgrade_all_pressed)
	
	# Open the dialog when the button is pressed
	add_local_btn.pressed.connect(func(): local_zip_dialog.popup_centered_ratio(0.7))
	
	# Send the selected path to the state manager
	local_zip_dialog.file_selected.connect(state_manager.install_local_zip)
	
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
		
	var remote_path = state_manager.data_dir.path_join(AppConfig.REMOTE_LIST_FILE)
	var remote_list = FileUtiles.load_json(remote_path, [])
		
	for repo in merged_list:
		var mod_data = installed_data.get(repo, {})
		var cur_version = mod_data.get("version", "")
		var is_enabled = mod_data.get("enabled", false)
		
		var display_name = mod_data.get("display_name", "")
		var description = mod_data.get("description", "")
		
		# If either string is empty, fallback to the remote list metadata
		if display_name.is_empty() or description.is_empty():
			for entry in remote_list:
				if entry is Dictionary:
					var entry_repo = String(entry.get("repo", "")).strip_edges()
					var target_repo = String(repo).strip_edges()
					if entry_repo == target_repo:
						if display_name.is_empty():
							display_name = String(entry.get("name", "")).strip_edges()
						if description.is_empty():
							description = String(entry.get("description", "")).strip_edges()
						break
			
		_spawn_mod_row(repo, cur_version, is_enabled, display_name, description)

func _spawn_mod_row(repo: String, current_version: String, is_enabled: bool, display_name: String = "", description: String = "") -> void:
	var row = MOD_ROW_SCENE.instantiate()
	mod_list_container.add_child(row)
	row.setup(repo, current_version, is_enabled, display_name, description)
	
	row.update_requested.connect(func(r, url, version): state_manager.begin_installation(r, url, version))
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
		row.install_progress.max_value = 100 # Reset from indeterminate state
		row.install_progress.visible = false
		if success:
			row.set_remote_info(row.latest_version, row.asset_download_url, row.latest_version)
			row.enable_check.button_pressed = true
			row.enable_check.disabled = false


func _on_upgrade_all_pressed() -> void:
	# Load the source of truth from disk
	var state = FileUtiles.load_json(state_manager.data_dir.path_join(AppConfig.MOD_STATE_FILE), {})
	var updates_started = 0
	
	for repo in state.keys():
		# Skip local ZIPs since they don't have GitHub releases
		if repo.begins_with("local/"): 
			continue
			
		var mod_data = state[repo]
		var current_version = mod_data.get("version", "")
		var remote_version = mod_data.get("remote_version", "")
		var remote_url = mod_data.get("remote_url", "")
		
		# ONLY update if current_version is not empty (meaning it is actually installed)
		if current_version != "" and current_version != remote_version and remote_version != "" and remote_url != "":
			state_manager.begin_installation(repo, remote_url, remote_version)
			updates_started += 1
			
	if updates_started == 0:
		state_manager.status_updated.emit("All installed mods are already up to date.")
	else:
		state_manager.status_updated.emit("Started " + str(updates_started) + " updates...")
