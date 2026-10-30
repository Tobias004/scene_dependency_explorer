@tool
extends RefCounted
## Builds a read-only hierarchy of statically instanced PackedScenes.
## The cache lives only for one analyze() call, so Refresh reads files again.

var _scan_cache: Dictionary = {}

## Returns {name, path, children, status} for the selected scene.
## status is empty, "cycle", or "unavailable".
func analyze(scene_path: String, root_name: String = "") -> Dictionary:
	_scan_cache.clear()
	if scene_path.is_empty():
		return {}
	if root_name.is_empty():
		root_name = scene_path.get_file().get_basename()
	return _expand(scene_path, root_name, {})

func _expand(scene_path: String, label: String, ancestors: Dictionary) -> Dictionary:
	var entry: Dictionary = {
		"name": label,
		"path": scene_path,
		"children": [],
		"status": "",
	}
	# Guard against a scene referencing an ancestor in the same branch.
	if ancestors.has(scene_path):
		entry["status"] = "cycle"
		return entry
	var scan: Dictionary = _scan_scene(scene_path)
	if not scan["ok"]:
		entry["status"] = "unavailable"
		return entry
	var next_ancestors: Dictionary = ancestors.duplicate()
	next_ancestors[scene_path] = true
	var records: Array = scan["instances"]
	var by_node_path: Dictionary = {}
	# Expand each occurrence separately, even when its file is shared.
	for record in records:
		var node_path: String = record["node_path"]
		var target_path: String = record["path"]
		var node_name: String = record["name"]
		by_node_path[node_path] = _expand(target_path, node_name, next_ancestors)
	# A saved instance nested below another saved instance belongs to that
	# instance. Ordinary nodes between them are shown as a compact path.
	for record in records:
		var node_path: String = record["node_path"]
		var closest_parent: String = ""
		for possible_parent in by_node_path:
			var prefix: String = str(possible_parent) + "/"
			if node_path.begins_with(prefix) and prefix.length() > closest_parent.length() + 1:
				closest_parent = str(possible_parent)
		var item: Dictionary = by_node_path[node_path]
		if not closest_parent.is_empty():
			item["name"] = node_path.substr(closest_parent.length() + 1)
			var parent_item: Dictionary = by_node_path[closest_parent]
			var siblings: Array = parent_item["children"]
			siblings.append(item)
		else:
			item["name"] = node_path
			var top_level: Array = entry["children"]
			top_level.append(item)
	return entry


func _scan_scene(scene_path: String) -> Dictionary:
	if _scan_cache.has(scene_path):
		return _scan_cache[scene_path]
	var result: Dictionary = {"ok": false, "instances": []}
	# IGNORE_DEEP reads the saved state without modifying editor-cached scenes.
	var scene: PackedScene = ResourceLoader.load(
		scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP
	) as PackedScene
	if scene == null:
		_scan_cache[scene_path] = result
		return result
	var state: SceneState = scene.get_state()
	if state == null:
		_scan_cache[scene_path] = result
		return result
	var instances: Array[Dictionary] = []
	var positions: Dictionary = {}
	_collect_state(state, instances, positions, {})
	result["ok"] = true
	result["instances"] = instances
	_scan_cache[scene_path] = result
	return result

func _collect_state(
	state: SceneState,
	instances: Array[Dictionary],
	positions: Dictionary,
	visited_states: Dictionary
) -> void:
	# Inherited scenes contain a base state plus local additions/overrides.
	# The base scene is NOT shown as a child instance of the derived root.
	var state_path: String = state.get_path()
	if visited_states.has(state_path):
		return
	visited_states[state_path] = true
	var base: SceneState = state.get_base_scene_state()
	if base != null:
		_collect_state(base, instances, positions, visited_states)
	for index in state.get_node_count():
		if index == 0:
			continue # Root node (including the inherited-scene root).
		var referenced_scene: PackedScene = state.get_node_instance(index)
		var target_path: String = ""
		if referenced_scene != null:
			target_path = referenced_scene.resource_path
		elif state.is_node_instance_placeholder(index):
			target_path = state.get_node_instance_placeholder(index)
		if not target_path.begins_with("res://"):
			continue
		var node_path: String = str(state.get_node_path(index))
		if node_path.is_empty() or node_path == ".":
			continue
		if node_path.begins_with("./"):
			node_path = node_path.substr(2)
		var record: Dictionary = {
			"node_path": node_path,
			"name": str(state.get_node_name(index)),
			"path": target_path,
		}
		if positions.has(node_path):
			# A derived scene can replace an instance from its base scene.
			instances[positions[node_path]] = record
		else:
			positions[node_path] = instances.size()
			instances.append(record)
