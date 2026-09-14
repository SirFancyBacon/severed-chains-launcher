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
		
		if response_code == 403:
			AppLogger.error("GitHub API Rate Limit %d on mod repo: %s" % [response_code, repo])
			
		var new_etag = ""
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
		
	if not saved_etag.is_empty():
		headers.append("If-None-Match: " + saved_etag)
		
	http.request(url, headers)

# --- Binary Downloading ---

func download_asset(repo: String, url: String, callback: Callable) -> void:
	if url.is_empty():
		AppLogger.error("Download failed: URL is empty for " + repo)
		print_rich()
		callback.call(false, PackedByteArray())
		return
		
	var http = HTTPRequest.new()
	add_child(http)
	
	var progress_timer = Timer.new()
	progress_timer.wait_time = 0.1
	progress_timer.autostart = true
	add_child(progress_timer)
	
	progress_timer.timeout.connect(func():
		if is_instance_valid(http) and http.get_http_client_status() == HTTPClient.STATUS_BODY:
			var total = http.get_body_size()
			var downloaded = http.get_downloaded_bytes()
			if total > 0:
				download_progress.emit(repo, downloaded, total)
	)
	
	http.request_completed.connect(func(_result, response_code, _headers, body):
		if is_instance_valid(progress_timer): progress_timer.queue_free()
		if is_instance_valid(http): http.queue_free()
		
		if response_code == 200:
			callback.call(true, body)
		else:
			AppLogger.error("Download Failed with code %d on mod repo: %s" % [response_code, repo])
			callback.call(false, PackedByteArray())
	)
	
	var headers = ["User-Agent: SeveredChains-Launcher"]
	var token = _get_github_token()
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
		
	var err = http.request(url, headers)
	if err != OK:
		if is_instance_valid(progress_timer): progress_timer.queue_free()
		if is_instance_valid(http): http.queue_free()
		callback.call(false, PackedByteArray())

# --- Internal Helpers ---

func _get_github_token() -> String:
	var base_dir = OS.get_executable_path().get_base_dir() if not OS.has_feature("editor") else ProjectSettings.globalize_path("res://")
	
	# Uses the centralized TOKEN_PATH from app_config.gd instead of manually constructing it
	var token_path = base_dir.path_join(AppConfig.TOKEN_PATH)
	
	if FileAccess.file_exists(token_path):
		var token_file = FileAccess.open(token_path, FileAccess.READ)
		return token_file.get_as_text().strip_edges()
	return ""

func validate_repo(repo: String, callback: Callable) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	
	http.request_completed.connect(func(_result, response_code, _headers, _body):
		http.queue_free()
		
		if response_code == 403:
			AppLogger.error("GitHub API Rate Limit %d on mod repo: %s" % [response_code, repo])
			
		callback.call(response_code == 200)
	)
	
	var url = AppConfig.GITHUB_API_URL + repo
	var headers = ["User-Agent: SeveredChains-Launcher"]
	
	var token = _get_github_token()
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
		
	http.request(url, headers, HTTPClient.METHOD_GET)
