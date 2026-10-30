@tool
extends EditorContextMenuPlugin
## Adds a scene bookmark action to Scene and FileSystem dock context menus.
## Each instance serves exactly one Godot context-menu slot.

var _store: RefCounted
var _for_scene_tree: bool = false

## Configures this menu before registering it with EditorPlugin.
func configure(store: RefCounted, scene_tree: bool) -> void:
	_store = store
	_for_scene_tree = scene_tree

func _popup_menu(paths: PackedStringArray) -> void:
	if _for_scene_tree:
		if _has_scene_node(EditorInterface.get_selection().get_selected_nodes()):
			add_context_menu_item("Add Scene Bookmark", _bookmark_scene_nodes)
	else:
		for path in paths:
			if _is_scene_file(path):
				add_context_menu_item("Add Scene Bookmark", _bookmark_files)
				return

func _bookmark_scene_nodes(nodes: Array) -> void:
	for value in nodes:
		if value is Node:
			var path: String = (value as Node).scene_file_path
			if _is_scene_file(path):
				_store.call("add_scene", path)

func _bookmark_files(paths: Array) -> void:
	for value in paths:
		var path: String = str(value)
		if _is_scene_file(path):
			_store.call("add_scene", path)

func _has_scene_node(nodes: Array[Node]) -> bool:
	for node in nodes:
		if _is_scene_file(node.scene_file_path):
			return true
	return false

func _is_scene_file(path: String) -> bool:
	return path.begins_with("res://") and (path.ends_with(".tscn") or path.ends_with(".scn")) and FileAccess.file_exists(path) and ResourceLoader.exists(path, "PackedScene")
