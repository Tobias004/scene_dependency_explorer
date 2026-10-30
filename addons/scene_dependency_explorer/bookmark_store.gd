@tool
extends RefCounted
## Stores personal, project-scoped scene bookmarks in Godot editor metadata.
## Keeps a UID and last known path so missing files remain visible.

signal changed
signal scene_added

const META_SECTION: String = "scene_dependency_explorer"
const META_KEY: String = "bookmarks"

var _entries: Array[Dictionary] = []

## Reads bookmarks from editor metadata without modifying the project.
func load_bookmarks() -> void:
	_entries.clear()
	var stored: Variant = EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, META_KEY, [])
	if stored is Array:
		for item in stored:
			if not item is Dictionary:
				continue
			var path: String = str(item.get("path", ""))
			if not _looks_like_scene_path(path):
				continue
			_entries.append({
				"path": path,
				"uid": str(item.get("uid", "")),
				"label": str(item.get("label", path.get_file().get_basename()))
			})
	reconcile()

## Adds a saved scene file, ignoring duplicate UIDs and paths.
func add_scene(path: String) -> bool:
	if not _is_existing_scene(path):
		return false
	reconcile()
	var uid: String = _uid_for_path(path)
	for entry in _entries:
		if str(entry["path"]) == path:
			return false
		if not uid.is_empty() and str(entry["uid"]) == uid:
			return false
	_entries.append({"path": path, "uid": uid, "label": path.get_file().get_basename()})
	_persist()
	changed.emit()
	scene_added.emit()
	return true

## Removes only the chosen bookmark; scene files are never touched.
func remove_at(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	_entries.remove_at(index)
	_persist()
	changed.emit()

## Returns resolved UI records. Invalid entries are retained and marked orphaned.
func get_items() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in _entries:
		var path: String = str(entry["path"])
		var valid: bool = _matches_saved_uid(path, str(entry["uid"]))
		result.append({
			"path": path,
			"uid": str(entry["uid"]),
			"label": str(entry["label"]),
			"valid": valid
		})
	return result

## Resolves UID-based moves while retaining the last known path if missing.
func reconcile() -> void:
	var was_updated: bool = false
	for entry in _entries:
		var uid: String = str(entry["uid"])
		var current_path: String = str(entry["path"])
		var resolved: String = _path_for_uid(uid)
		if not resolved.is_empty() and _matches_saved_uid(resolved, uid):
			if current_path != resolved:
				entry["path"] = resolved
				current_path = resolved
				was_updated = true
		elif _is_existing_scene(current_path):
			var actual_uid: String = _uid_for_path(current_path)
			if uid.is_empty() and not actual_uid.is_empty():
				entry["uid"] = actual_uid
				was_updated = true
			elif not uid.is_empty() and not actual_uid.is_empty() and actual_uid != uid:
				# The old path was reused by a different scene. Do not adopt it.
				continue
		else:
			continue
		if _is_existing_scene(current_path):
			var new_label: String = current_path.get_file().get_basename()
			if str(entry["label"]) != new_label:
				entry["label"] = new_label
				was_updated = true
	if was_updated:
		_persist()
	changed.emit()

## Tracks a move made through Godot's FileSystem dock immediately.
func file_moved(old_path: String, new_path: String) -> void:
	var updated: bool = false
	for entry in _entries:
		if str(entry["path"]) == old_path:
			entry["path"] = new_path
			entry["label"] = new_path.get_file().get_basename()
			updated = true
	if updated:
		_persist()
	reconcile()

## Updates paths for moved folders without altering any scene resources.
func folder_moved(old_path: String, new_path: String) -> void:
	var old_prefix: String = old_path.trim_suffix("/") + "/"
	var new_prefix: String = new_path.trim_suffix("/") + "/"
	var updated: bool = false
	for entry in _entries:
		var path: String = str(entry["path"])
		if path.begins_with(old_prefix):
			entry["path"] = new_prefix + path.substr(old_prefix.length())
			updated = true
	if updated:
		_persist()
	reconcile()

func _persist() -> void:
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, META_KEY, _entries.duplicate(true))

func _looks_like_scene_path(path: String) -> bool:
	return path.begins_with("res://") and (path.ends_with(".tscn") or path.ends_with(".scn"))

func _is_existing_scene(path: String) -> bool:
	return _looks_like_scene_path(path) and FileAccess.file_exists(path) and ResourceLoader.exists(path, "PackedScene")

func _matches_saved_uid(path: String, saved_uid: String) -> bool:
	if not _is_existing_scene(path):
		return false
	if saved_uid.is_empty():
		return true
	var file_uid: String = _uid_for_path(path)
	# An unindexed resource is still reachable by its saved path. If the path
	# carries a different registered UID, it is a replacement, not our scene.
	return file_uid.is_empty() or file_uid == saved_uid

func _uid_for_path(path: String) -> String:
	var uid: String = ResourceUID.path_to_uid(path)
	return uid if uid.begins_with("uid://") else ""

func _path_for_uid(uid: String) -> String:
	if not uid.begins_with("uid://"):
		return ""
	var id: int = ResourceUID.text_to_id(uid)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)
