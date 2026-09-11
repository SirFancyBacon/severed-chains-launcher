extends Node
class_name ModNetworker

# We only emit a signal for ongoing download progress. 
# Everything else returns via Callables to keep the logic flow linear in the State Manager.
signal download_progress(repo: String, current_bytes: int, total_bytes: int)

# --- Dual-List Synchronization ---

func fetch_official_list(callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		var official_list: Array = []
		
		if response_code == 200:
			var json = JSON.new()
			if json.parse(body.get_string_from_utf8()) == OK and json.data is Array:
				official_list = json.data
				
		callback.call(official_list)
	)
	
	http.request(AppConfig.OFFICIAL_MOD_LIST_URL, ["User-Agent: SeveredChains-Launcher"])

# --- API & Release Fetching ---

func fetch_mod_release(repo: String, saved_etag: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, headers, body):
		http.queue_free()
		var new_etag = ""
		
		# GitHub uses ETags to tell us if a release has changed since we last checked
		for header in headers:
			if header.to_lower().begins_with("etag:"):
				new_etag = header.split(":", true, 1)[1].strip_edges()
				break
		
		var release_data: Dictionary = {}
		if response_code == 200:
			var json = JSON.new()
			if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
				release_data = json.data
				
		callback.call(response_code, release_data, new_etag)
	)
	
	var url = AppConfig.GITHUB_API_URL + repo + "/releases/latest"
	var headers = ["User-Agent: SeveredChains-Launcher"]
	
	var token = _get_github_token()
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
		
	# If we already checked this recently, ask GitHub to return a 304 Not Modified to save API calls
	if not saved_etag.is_empty():
		headers.append("If-None-Match: " + saved_etag)
		
	http.request(url, headers)

# --- Binary Downloading ---

func download_asset(repo: String, url: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	# We need to track the HTTPRequest dynamically to poll for download progress
	var progress_timer = Timer.new()
	progress_timer.wait_time = 0.1
	progress_timer.autostart = true
	add_child(progress_timer)
	
	progress_timer.timeout.connect(func():
		if http.get_http_client_status() == HTTPClient.STATUS_BODY:
			var total = http.get_body_size()
			var downloaded = http.get_downloaded_bytes()
			if total > 0:
				download_progress.emit(repo, downloaded, total)
	)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		progress_timer.queue_free()
		http.queue_free()
		
		if response_code == 200:
			callback.call(true, body)
		else:
			callback.call(false, PackedByteArray())
	)
	
	http.request(url, ["User-Agent: SeveredChains-Launcher"])

# --- Internal Helpers ---

func _get_github_token() -> String:
	# Replace with your actual base_dir access method, or ensure AppConfig path is absolute
	var base_dir = OS.get_executable_path().get_base_dir() if not OS.has_feature("editor") else ProjectSettings.globalize_path("res://")
	var token_path = base_dir.path_join(AppConfig.MOD_DATA_DIR).path_join("github_api_token.txt")
	
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		return token_file.get_as_text().strip_edges()
	return ""
