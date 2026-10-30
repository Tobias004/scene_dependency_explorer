@tool
extends VBoxContainer
## Read-only hierarchy with a space-saving bookmark popup in the toolbar.
## The editor plugin handles navigation, bookmark persistence and drag results.

signal refresh_requested
signal scene_open_requested(path: String)
signal back_requested
signal forward_requested
signal main_scene_requested
signal bookmark_add_requested(path: String)
signal bookmark_remove_requested(index: int)
signal bookmarks_dropped(paths: PackedStringArray)

const BookmarkListIcon = preload("res://addons/scene_dependency_explorer/icons/bookmark_list.svg")

var _tree: Tree
var _message: Label
var _back_button: Button
var _forward_button: Button
var _main_button: Button
var _bookmark_menu_button: MenuButton
var _bookmark_toggle_button: Button
var _remove_bookmark_menu: PopupMenu
var _bookmarks: Array[Dictionary] = []
var _current_scene_path: String = ""


func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	var toolbar := HBoxContainer.new()
	add_child(toolbar)
	_back_button = Button.new()
	_back_button.text = "←"
	_back_button.tooltip_text = "Go back to the previous scene"
	_back_button.disabled = true
	_back_button.pressed.connect(func() -> void: back_requested.emit())
	toolbar.add_child(_back_button)
	_forward_button = Button.new()
	_forward_button.text = "→"
	_forward_button.tooltip_text = "Go forward to the next scene"
	_forward_button.disabled = true
	_forward_button.pressed.connect(func() -> void: forward_requested.emit())
	toolbar.add_child(_forward_button)
	_main_button = Button.new()
	_main_button.text = "Main"
	_main_button.tooltip_text = "Open the main scene configured in Project Settings"
	_main_button.disabled = true
	_main_button.pressed.connect(func() -> void: main_scene_requested.emit())
	toolbar.add_child(_main_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	var refresh_button := Button.new()
	refresh_button.text = "Refresh"
	refresh_button.tooltip_text = "Re-analyze saved scene files"
	refresh_button.pressed.connect(func() -> void: refresh_requested.emit())
	toolbar.add_child(refresh_button)
	_bookmark_menu_button = MenuButton.new()
	_bookmark_menu_button.icon = BookmarkListIcon
	_bookmark_menu_button.custom_minimum_size = Vector2(28, 0)
	_bookmark_menu_button.tooltip_text = "Open scene bookmarks"
	_bookmark_menu_button.about_to_popup.connect(_populate_bookmark_menu)
	toolbar.add_child(_bookmark_menu_button)
	var popup: PopupMenu = _bookmark_menu_button.get_popup()
	popup.id_pressed.connect(_on_bookmark_menu_item_pressed)
	_remove_bookmark_menu = PopupMenu.new()
	_remove_bookmark_menu.name = "RemoveBookmarkMenu"
	popup.add_child(_remove_bookmark_menu)
	_remove_bookmark_menu.id_pressed.connect(_on_remove_bookmark_menu_item_pressed)
	_bookmark_toggle_button = Button.new()
	_bookmark_toggle_button.custom_minimum_size = Vector2(28, 0)
	_bookmark_toggle_button.pressed.connect(_toggle_current_bookmark)
	toolbar.add_child(_bookmark_toggle_button)
	_update_bookmark_controls()
	var separator := HSeparator.new()
	add_child(separator)
	_message = Label.new()
	_message.text = "Open a saved scene to inspect its dependencies."
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = false
	_tree.columns = 1
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)

## Enables available navigation destinations; unavailable ones stay disabled.
func set_navigation_state(can_back: bool, can_forward: bool, has_main_scene: bool) -> void:
	_back_button.disabled = not can_back
	_forward_button.disabled = not can_forward
	_main_button.disabled = not has_main_scene

## Updates the bookmark action for the currently edited scene.
func set_current_scene(path: String) -> void:
	_current_scene_path = path
	_update_bookmark_controls()

## Replaces the displayed bookmark records without changing their order.
func set_bookmarks(items: Array[Dictionary]) -> void:
	_bookmarks = items
	_update_bookmark_controls()

## Displays a placeholder when no saved scene is active.
func show_message(message: String) -> void:
	_tree.clear()
	_tree.hide()
	_message.text = message
	_message.show()

## Displays scene entries, omitting ordinary intermediate nodes.
func show_hierarchy(hierarchy: Dictionary) -> void:
	_tree.clear()
	_message.hide()
	_tree.show()
	_append_entry(null, hierarchy)

## Accepts Godot's native Scene dock node drags and FileSystem file drags.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return not _extract_scene_paths(data).is_empty()

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var paths: PackedStringArray = _extract_scene_paths(data)
	if not paths.is_empty():
		bookmarks_dropped.emit(paths)

func _extract_scene_paths(data: Variant) -> PackedStringArray:
	var paths := PackedStringArray()
	if not data is Dictionary:
		return paths
	var payload: Dictionary = data
	var data_type: String = str(payload.get("type", ""))
	if data_type == "files":
		var files: Variant = payload.get("files", [])
		if files is Array or files is PackedStringArray:
			for value in files:
				var path: String = str(value)
				if _is_scene_file(path) and not paths.has(path):
					paths.append(path)
	elif data_type == "nodes":
		var nodes: Variant = payload.get("nodes", [])
		if nodes is Array:
			for value in nodes:
				var node: Node = null
				if value is Node:
					node = value
				elif value is NodePath or value is String:
					# Scene dock drags contain editor-tree paths, not paths
					# relative to this dock.
					var node_path := NodePath(str(value))
					if node_path.is_absolute():
						node = get_tree().root.get_node_or_null(node_path)
					else:
						var edited_root: Node = EditorInterface.get_edited_scene_root()
						if edited_root != null:
							node = edited_root.get_node_or_null(node_path)
				if node != null:
					var path: String = node.scene_file_path
					if _is_scene_file(path) and not paths.has(path):
						paths.append(path)
	return paths

func _is_scene_file(path: String) -> bool:
	return path.begins_with("res://") and (path.ends_with(".tscn") or path.ends_with(".scn")) and FileAccess.file_exists(path) and ResourceLoader.exists(path, "PackedScene")

func _find_current_bookmark() -> int:
	for index in range(_bookmarks.size()):
		var entry: Dictionary = _bookmarks[index]
		if bool(entry.get("valid", false)) and str(entry.get("path", "")) == _current_scene_path:
			return index
	return -1

func _update_bookmark_controls() -> void:
	if _bookmark_menu_button == null or _bookmark_toggle_button == null:
		return
	_bookmark_menu_button.tooltip_text = "Bookmarks (%d) – click to open list; drop scenes onto the dock to add" % _bookmarks.size()
	var has_scene: bool = _is_scene_file(_current_scene_path)
	var is_bookmarked: bool = has_scene and _find_current_bookmark() >= 0
	_bookmark_toggle_button.disabled = not has_scene
	_bookmark_toggle_button.text = "★" if is_bookmarked else "☆"
	_bookmark_toggle_button.tooltip_text = "Remove current scene bookmark" if is_bookmarked else "Bookmark current scene"

func _toggle_current_bookmark() -> void:
	if not _is_scene_file(_current_scene_path):
		return
	var index: int = _find_current_bookmark()
	if index >= 0:
		bookmark_remove_requested.emit(index)
	else:
		bookmark_add_requested.emit(_current_scene_path)

func _populate_bookmark_menu() -> void:
	var popup: PopupMenu = _bookmark_menu_button.get_popup()
	popup.clear()
	_remove_bookmark_menu.clear()
	if _bookmarks.is_empty():
		popup.add_item("No bookmarks")
		popup.set_item_disabled(0, true)
		return
	for index in range(_bookmarks.size()):
		var entry: Dictionary = _bookmarks[index]
		var valid: bool = bool(entry.get("valid", false))
		var label: String = str(entry.get("label", "Scene"))
		var path: String = str(entry.get("path", ""))
		popup.add_item(label if valid else "⚠ %s (missing)" % label, index)
		popup.set_item_disabled(index, not valid)
		popup.set_item_tooltip(index, path if valid else "Orphaned bookmark: " + path)
		_remove_bookmark_menu.add_item(label, index)
		_remove_bookmark_menu.set_item_tooltip(index, "Remove bookmark only: " + path)
	popup.add_separator()
	popup.add_submenu_node_item("Remove bookmark…", _remove_bookmark_menu)

func _on_bookmark_menu_item_pressed(index: int) -> void:
	if index < 0 or index >= _bookmarks.size():
		return
	var entry: Dictionary = _bookmarks[index]
	if bool(entry.get("valid", false)):
		scene_open_requested.emit(str(entry.get("path", "")))

func _on_remove_bookmark_menu_item_pressed(index: int) -> void:
	if index >= 0 and index < _bookmarks.size():
		bookmark_remove_requested.emit(index)

func _append_entry(parent: TreeItem, entry: Dictionary) -> void:
	var item: TreeItem = _tree.create_item(parent)
	var label: String = str(entry.get("name", ""))
	var status: String = str(entry.get("status", ""))
	if status == "cycle":
		label += " (circular reference)"
	elif status == "unavailable":
		label += " (unavailable)"
	item.set_text(0, label)
	var path: String = str(entry.get("path", ""))
	item.set_metadata(0, path)
	item.set_tooltip_text(0, path)
	if has_theme_icon("Instance", "EditorIcons"):
		item.set_icon(0, get_theme_icon("Instance", "EditorIcons"))
	var children: Array = entry.get("children", [])
	for child in children:
		_append_entry(item, child)

func _on_item_activated() -> void:
	var selected: TreeItem = _tree.get_selected()
	if selected == null:
		return
	var path: String = str(selected.get_metadata(0))
	if path.begins_with("res://"):
		scene_open_requested.emit(path)
