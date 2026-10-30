@tool
extends EditorPlugin
## Integrates scene analysis, navigation and project-scoped personal bookmarks.

const AnalyzerScript = preload("res://addons/scene_dependency_explorer/scene_analyzer.gd")
const DockScript = preload("res://addons/scene_dependency_explorer/scene_explorer_dock.gd")
const BookmarkStoreScript = preload("res://addons/scene_dependency_explorer/bookmark_store.gd")
const BookmarkContextMenuScript = preload("res://addons/scene_dependency_explorer/bookmark_context_menu.gd")
const DockIcon = preload("res://addons/scene_dependency_explorer/icons/scene_dependencies.svg")

var _analyzer: RefCounted
var _dock: Control
var _bookmarks: RefCounted
var _scene_menu: EditorContextMenuPlugin
var _file_menu: EditorContextMenuPlugin
var _history: Array[String] = []
var _history_index: int = -1
var _pending_history_index: int = -1


func _enter_tree() -> void:
	_analyzer = AnalyzerScript.new()
	_bookmarks = BookmarkStoreScript.new()
	_bookmarks.call("load_bookmarks")
	_bookmarks.connect("changed", _on_bookmarks_changed)
	_dock = DockScript.new()
	_dock.name = "Scene Dependencies"
	_dock.connect("refresh_requested", _refresh)
	_dock.connect("scene_open_requested", _open_scene)
	_dock.connect("back_requested", _go_back)
	_dock.connect("forward_requested", _go_forward)
	_dock.connect("main_scene_requested", _open_main_scene)
	_dock.connect("bookmark_add_requested", _add_bookmark)
	_dock.connect("bookmark_remove_requested", _remove_bookmark)
	_dock.connect("bookmarks_dropped", _add_dropped_bookmarks)
	add_control_to_dock(DOCK_SLOT_LEFT_UR, _dock)
	set_dock_tab_icon(_dock, DockIcon)
	_scene_menu = BookmarkContextMenuScript.new()
	_scene_menu.call("configure", _bookmarks, true)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_menu)
	_file_menu = BookmarkContextMenuScript.new()
	_file_menu.call("configure", _bookmarks, false)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _file_menu)
	var file_dock: FileSystemDock = EditorInterface.get_file_system_dock()
	file_dock.files_moved.connect(_on_file_moved)
	file_dock.folder_moved.connect(_on_folder_moved)
	file_dock.file_removed.connect(_on_file_removed)
	file_dock.folder_removed.connect(_on_folder_removed)
	scene_changed.connect(_on_scene_changed)
	call_deferred("_initialize")

func _exit_tree() -> void:
	scene_changed.disconnect(_on_scene_changed)
	var file_dock: FileSystemDock = EditorInterface.get_file_system_dock()
	file_dock.files_moved.disconnect(_on_file_moved)
	file_dock.folder_moved.disconnect(_on_folder_moved)
	file_dock.file_removed.disconnect(_on_file_removed)
	file_dock.folder_removed.disconnect(_on_folder_removed)
	remove_context_menu_plugin(_scene_menu)
	remove_context_menu_plugin(_file_menu)
	_scene_menu = null
	_file_menu = null
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_bookmarks = null

func _initialize() -> void:
	if not is_instance_valid(_dock):
		return
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		_record_active_scene(root.scene_file_path)
	_refresh()

func _on_scene_changed(scene_root: Node) -> void:
	var path: String = ""
	if scene_root != null:
		path = scene_root.scene_file_path
	if not path.is_empty():
		if _pending_history_index >= 0 and _history[_pending_history_index] == path:
			_history_index = _pending_history_index
		else:
			_record_active_scene(path)
	_pending_history_index = -1
	_refresh()

func _record_active_scene(path: String) -> void:
	if not path.begins_with("res://"):
		return
	if _history_index >= 0 and _history[_history_index] == path:
		return
	_history.resize(_history_index + 1)
	_history.append(path)
	_history_index = _history.size() - 1

func _refresh() -> void:
	if not is_instance_valid(_dock):
		return
	_bookmarks.call("reconcile")
	_update_navigation_buttons()
	var edited_root: Node = EditorInterface.get_edited_scene_root()
	var path: String = "" if edited_root == null else edited_root.scene_file_path
	_dock.call("set_current_scene", path)
	if path.is_empty():
		_dock.call("show_message", "Open a saved scene to inspect its dependencies.")
		return
	var result: Dictionary = _analyzer.call("analyze", path, str(edited_root.name))
	_dock.call("show_hierarchy", result)

func _on_bookmarks_changed() -> void:
	if is_instance_valid(_dock):
		_dock.call("set_bookmarks", _bookmarks.call("get_items"))

func _add_bookmark(path: String) -> void:
	_bookmarks.call("add_scene", path)

func _add_dropped_bookmarks(paths: PackedStringArray) -> void:
	for path in paths:
		_add_bookmark(path)

func _remove_bookmark(index: int) -> void:
	_bookmarks.call("remove_at", index)

func _on_file_moved(old_path: String, new_path: String) -> void:
	_bookmarks.call("file_moved", old_path, new_path)

func _on_folder_moved(old_path: String, new_path: String) -> void:
	_bookmarks.call("folder_moved", old_path, new_path)

func _on_file_removed(_path: String) -> void:
	_bookmarks.call("reconcile")

func _on_folder_removed(_path: String) -> void:
	_bookmarks.call("reconcile")

func _open_scene(path: String) -> void:
	if _is_scene_path(path):
		EditorInterface.open_scene_from_path(path)

func _go_back() -> void:
	_navigate_history(_history_index - 1)

func _go_forward() -> void:
	_navigate_history(_history_index + 1)

func _navigate_history(index: int) -> void:
	if _pending_history_index >= 0 or index < 0 or index >= _history.size():
		return
	var path: String = _history[index]
	if not _is_scene_path(path):
		return
	_pending_history_index = index
	_update_navigation_buttons()
	EditorInterface.open_scene_from_path(path)

func _open_main_scene() -> void:
	var path: String = _get_main_scene_path()
	if not path.is_empty():
		_open_scene(path)

func _get_main_scene_path() -> String:
	var path: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if path.begins_with("uid://"):
		var id: int = ResourceUID.text_to_id(path)
		if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
			return ""
		path = ResourceUID.get_id_path(id)
	return path if _is_scene_path(path) else ""

func _is_scene_path(path: String) -> bool:
	return path.begins_with("res://") and FileAccess.file_exists(path) and ResourceLoader.exists(path, "PackedScene")

func _update_navigation_buttons() -> void:
	if not is_instance_valid(_dock):
		return
	var can_navigate: bool = _pending_history_index < 0
	_dock.call(
		"set_navigation_state",
		can_navigate and _history_index > 0,
		can_navigate and _history_index >= 0 and _history_index < _history.size() - 1,
		not _get_main_scene_path().is_empty()
	)
