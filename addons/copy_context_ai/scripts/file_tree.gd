# file_tree.gd
# Script para el nodo Tree en la escena del plugin CopyContextAI
@tool
extends Tree

# --- Límite de caracteres ---
const MAX_CONTEXT_CHARS: int = 700000
const FILE_DETAIL_TAG_OVERHEAD: int = 60

# --- Enums and Constants ---
enum CheckState { UNCHECKED, CHECKED, INDETERMINATE }

const IGNORED_EXTENSIONS: PackedStringArray = ["import", "godot-uid", "uid", "tmp", "convert"]
const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "svg", "tga", "bmp", "exr", "hdr"]
const TEXT_EXTENSIONS: PackedStringArray = [
	"gd", "cs", # Scripts
	"tscn", "scn", "tres", "res", # Escenas y Recursos Godot
	"shader", "gdshader", "gdshaderinc", # Shaders
	"json", "xml", "csv", "ini", "cfg", "toml", "yaml", "yml", "url", # Datos y Config
	"txt", "md", "log", # Texto plano y Markdown
	"godot", "project", # Archivos de proyecto
	"mtl" # Materiales OBJ
]

const MAX_SUMMARY_LINES: int = 3
const META_STATE: StringName = &"state"
const META_PATH: StringName = &"path"
const FOLDER_ICON_COLOR: Color = Color(0.6071, 0.8125, 0.9866, 1.0)

# --- Variables ---
var preview_requests: Dictionary = {}
var resource_previewer: EditorResourcePreview = null
var _is_handling_edit: bool = false
var _path_to_item_lookup: Dictionary = {}

# --- Variables de límite ---
var _current_context_chars: int = 0
var _context_limit_reached: bool = false
var _limit_reached_message: String = "--- (Context character limit reached; content omitted) ---"
var _limit_reached_before_message: String = "--- (Context limit reached before this file) ---"
var _non_text_omitted_message: String = "--- (Content omitted; non-text or excluded type) ---"
var _read_error_message: String = "--- (Error reading file content) ---"
var _file_not_found_message: String = "--- (Error: File not found at path) ---"

# --- Initialization and Tree Population ---

func _ready() -> void:
	set_columns(1)
	set_column_titles_visible(false)
	select_mode = Tree.SELECT_ROW

	if not item_edited.is_connected(_on_item_edited):
		item_edited.connect(_on_item_edited)

	# <<< AÑADIDO >>> Conectar la señal para detectar clics de ratón en los ítems
	if not item_mouse_selected.is_connected(_on_item_mouse_selected):
		item_mouse_selected.connect(_on_item_mouse_selected)

	if Engine.is_editor_hint():
		resource_previewer = EditorInterface.get_resource_previewer()
		if not resource_previewer:
			printerr("CopyContextAI: Could not get EditorResourcePreviewer.")
		call_deferred("populate_tree")


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE:
		if preview_requests != null:
			preview_requests.clear()
		resource_previewer = null
		if item_edited.is_connected(_on_item_edited):
			item_edited.disconnect(_on_item_edited)

		# <<< AÑADIDO >>> Desconectar la señal al salir del árbol
		if item_mouse_selected.is_connected(_on_item_mouse_selected):
			item_mouse_selected.disconnect(_on_item_mouse_selected)

		_path_to_item_lookup.clear()


func populate_tree() -> void:
	if not Engine.is_editor_hint():
		return

	# 1. Save current states before clearing the tree
	var previous_states: Dictionary = {}
	if is_instance_valid(get_root()):
		var stack: Array[TreeItem] = [get_root()]
		while not stack.is_empty():
			var item: TreeItem = stack.pop_back()
			if not is_instance_valid(item):
				continue

			var meta: Dictionary = item.get_metadata(0)
			if meta is Dictionary:
				var state: CheckState = meta.get(META_STATE, CheckState.UNCHECKED)
				if state != CheckState.UNCHECKED:
					var path: String = meta.get(META_PATH, "")
					if not path.is_empty():
						previous_states[path] = state

			var child: TreeItem = item.get_first_child()
			while is_instance_valid(child):
				stack.append(child)
				child = child.get_next()

	if preview_requests == null:
		preview_requests = {}

	var was_handling: bool = _is_handling_edit
	_is_handling_edit = true

	clear()
	preview_requests.clear()
	_path_to_item_lookup.clear()

	var root: TreeItem = create_item()
	if not is_instance_valid(root):
		_is_handling_edit = was_handling
		printerr("CopyContextAI: Failed to create root TreeItem.")
		return

	root.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	root.set_editable(0, true)
	root.set_checked(0, false)
	root.set_indeterminate(0, false)
	root.set_text(0, "res://")
	root.set_icon(0, get_theme_icon(&"Folder", &"EditorIcons"))
	root.set_icon_modulate(0, FOLDER_ICON_COLOR)
	root.set_metadata(0, { META_STATE: CheckState.UNCHECKED, META_PATH: "res://" } )
	_path_to_item_lookup["res://"] = root

	_scan_dir("res://", root)

	# 2. Restore the saved states to the newly created items
	if not previous_states.is_empty():
		for path in previous_states:
			if path in _path_to_item_lookup:
				var item_to_restore: TreeItem = _path_to_item_lookup[path]
				var saved_state: CheckState = previous_states[path]

				if is_instance_valid(item_to_restore):
					var meta: Dictionary = item_to_restore.get_metadata(0)
					if not meta is Dictionary: meta = {}
					meta[META_STATE] = saved_state
					item_to_restore.set_metadata(0, meta)
					
					match saved_state:
						CheckState.CHECKED:
							item_to_restore.set_checked(0, true)
							item_to_restore.set_indeterminate(0, false)
						CheckState.INDETERMINATE:
							item_to_restore.set_checked(0, false)
							item_to_restore.set_indeterminate(0, true)

	# 3. Update all folder states from the bottom up to ensure consistency
	_update_all_folder_states()

	_is_handling_edit = was_handling
	print("CopyContextAI: FileTree populated and states restored.")


func _scan_dir(path: String, parent_item: TreeItem) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if not dir:
		printerr("CopyContextAI: Error opening directory: ", path)
		return

	var subdirs: PackedStringArray = []
	var files: PackedStringArray = []

	dir.list_dir_begin()
	var item_name: String = dir.get_next()
	while item_name != "":
		if item_name.begins_with("."):
			item_name = dir.get_next()
			continue

		var extension: String = item_name.get_extension().to_lower()
		if extension in IGNORED_EXTENSIONS:
			item_name = dir.get_next()
			continue

		if dir.current_is_dir():
			subdirs.append(item_name)
		else:
			files.append(item_name)

		item_name = dir.get_next()

	dir.list_dir_end()

	subdirs.sort()
	files.sort()

	for dir_name in subdirs:
		var full_path: String = path.path_join(dir_name)
		var new_item: TreeItem = _create_tree_item(parent_item, dir_name, full_path, true)
		if is_instance_valid(new_item):
			_scan_dir(full_path, new_item)
			new_item.collapsed = true

	for file_name in files:
		var full_path: String = path.path_join(file_name)
		_create_tree_item(parent_item, file_name, full_path, false)


func _create_tree_item(parent_item: TreeItem, item_name: String, full_path: String, is_dir: bool) -> TreeItem:
	var new_item: TreeItem = create_item(parent_item)
	if not is_instance_valid(new_item):
		printerr("CopyContextAI: Failed to create TreeItem for ", item_name)
		return null

	new_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	new_item.set_editable(0, true)
	new_item.set_checked(0, false)
	new_item.set_indeterminate(0, false)
	new_item.set_text(0, item_name)

	var item_meta: Dictionary = { META_STATE: CheckState.UNCHECKED, META_PATH: full_path }
	new_item.set_metadata(0, item_meta)
	_path_to_item_lookup[full_path] = new_item

	if is_dir:
		new_item.set_icon(0, get_theme_icon(&"Folder", &"EditorIcons"))
		new_item.set_icon_modulate(0, FOLDER_ICON_COLOR)
	else:
		var extension: String = item_name.get_extension().to_lower()
		var icon_name: StringName = &""
		if Engine.is_editor_hint():
			var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
			if editor_settings:
				var icon_provider = editor_settings.get_setting("filesystem/file_dialog/icon_provider")
				if icon_provider and icon_provider.has_method("get_file_icon_name"):
					icon_name = icon_provider.get_file_icon_name(item_name)

		if not icon_name.is_empty() and has_theme_icon(icon_name, &"EditorIcons"):
			new_item.set_icon(0, get_theme_icon(icon_name, &"EditorIcons"))
		else:
			new_item.set_icon(0, _get_icon_for_file_fallback(extension))

		if resource_previewer and extension in IMAGE_EXTENSIONS:
			if not full_path in preview_requests:
				preview_requests[full_path] = new_item
				if resource_previewer.has_method("queue_resource_preview"):
					var user_data: Dictionary = { META_PATH: full_path }
					resource_previewer.queue_resource_preview(full_path, self, "_on_preview_ready", user_data)
				#else: error already printed

	return new_item


# --- Checkbox State Logic ---
func _on_item_edited() -> void:
	if _is_handling_edit:
		return
	var item: TreeItem = get_edited()
	if not is_instance_valid(item) or get_edited_column() != 0:
		return

	_is_handling_edit = true
	var current_meta: Dictionary = item.get_metadata(0)
	if not current_meta is Dictionary:
		current_meta = { META_STATE: CheckState.UNCHECKED }

	var previous_logical_state: CheckState = current_meta.get(META_STATE, CheckState.UNCHECKED)
	var new_logical_state: CheckState = CheckState.UNCHECKED

	match previous_logical_state:
		CheckState.UNCHECKED:
			new_logical_state = CheckState.CHECKED
		CheckState.CHECKED:
			new_logical_state = CheckState.INDETERMINATE
		CheckState.INDETERMINATE:
			new_logical_state = CheckState.UNCHECKED

	_set_item_state_recursive(item, new_logical_state)
	_update_ancestor_state(item.get_parent())
	_is_handling_edit = false


func _set_item_state_recursive(item: TreeItem, state: CheckState) -> void:
	if not is_instance_valid(item):
		return
	var meta: Dictionary = item.get_metadata(0)
	if not meta is Dictionary:
		meta = {}
	meta[META_STATE] = state
	item.set_metadata(0, meta)

	match state:
		CheckState.UNCHECKED:
			item.set_checked(0, false)
			item.set_indeterminate(0, false)
		CheckState.CHECKED:
			item.set_checked(0, true)
			item.set_indeterminate(0, false)
		CheckState.INDETERMINATE:
			item.set_checked(0, false)
			item.set_indeterminate(0, true)

	var child: TreeItem = item.get_first_child()
	while is_instance_valid(child):
		_set_item_state_recursive(child, state)
		child = child.get_next()


func _update_parent_state_from_children(item: TreeItem) -> bool:
	if not is_instance_valid(item) or item.get_child_count() == 0:
		return false

	var first_child_state: int = -1
	var has_mixed_states: bool = false
	var child: TreeItem = item.get_first_child()

	while is_instance_valid(child):
		var child_meta: Dictionary = child.get_metadata(0)
		var child_state: CheckState = CheckState.UNCHECKED
		if child_meta is Dictionary:
			child_state = child_meta.get(META_STATE, CheckState.UNCHECKED)

		if child_state == CheckState.INDETERMINATE:
			has_mixed_states = true
			break
		if first_child_state == -1:
			first_child_state = child_state
		elif child_state != first_child_state:
			has_mixed_states = true
			break
		child = child.get_next()

	var new_parent_logical_state: CheckState
	if has_mixed_states:
		new_parent_logical_state = CheckState.INDETERMINATE
	elif first_child_state != -1:
		new_parent_logical_state = first_child_state
	else:
		new_parent_logical_state = CheckState.UNCHECKED

	var current_parent_meta: Dictionary = item.get_metadata(0)
	var current_parent_logical_state: CheckState = CheckState.UNCHECKED
	if current_parent_meta is Dictionary:
		current_parent_logical_state = current_parent_meta.get(META_STATE, CheckState.UNCHECKED)

	if current_parent_logical_state != new_parent_logical_state:
		if not current_parent_meta is Dictionary:
			current_parent_meta = {}
		current_parent_meta[META_STATE] = new_parent_logical_state
		item.set_metadata(0, current_parent_meta)
		match new_parent_logical_state:
			CheckState.UNCHECKED:
				item.set_checked(0, false)
				item.set_indeterminate(0, false)
			CheckState.CHECKED:
				item.set_checked(0, true)
				item.set_indeterminate(0, false)
			CheckState.INDETERMINATE:
				item.set_checked(0, false)
				item.set_indeterminate(0, true)
		return true # State changed
	else:
		return false # State did not change


func _update_ancestor_state(item: TreeItem) -> void:
	while is_instance_valid(item):
		if not _update_parent_state_from_children(item):
			break
		item = item.get_parent()


func _update_all_folder_states() -> void:
	var was_handling: bool = _is_handling_edit
	_is_handling_edit = true
	var items_to_process: Array[TreeItem] = []
	var root: TreeItem = get_root()
	if is_instance_valid(root):
		var stack: Array = [root]
		while not stack.is_empty():
			var current: TreeItem = stack.pop_back()
			if is_instance_valid(current):
				items_to_process.append(current)
				var child: TreeItem = current.get_first_child()
				while is_instance_valid(child):
					stack.append(child)
					child = child.get_next()

	for i in range(items_to_process.size() - 1, -1, -1):
		var item: TreeItem = items_to_process[i]
		if is_instance_valid(item) and item.get_child_count() > 0:
			_force_recalculate_parent_visual_state(item)
	_is_handling_edit = was_handling


func _force_recalculate_parent_visual_state(item: TreeItem) -> void:
	if not is_instance_valid(item) or item.get_child_count() == 0:
		return
	var first_child_state: int = -1
	var has_mixed_states: bool = false
	var child: TreeItem = item.get_first_child()
	while is_instance_valid(child):
		var child_meta: Dictionary = child.get_metadata(0)
		var child_state: CheckState = CheckState.UNCHECKED
		if child_meta is Dictionary:
			child_state = child_meta.get(META_STATE, CheckState.UNCHECKED)
		if child_state == CheckState.INDETERMINATE:
			has_mixed_states = true; break
		if first_child_state == -1:
			first_child_state = child_state
		elif child_state != first_child_state:
			has_mixed_states = true; break
		child = child.get_next()

	var new_parent_logical_state: CheckState
	if has_mixed_states: new_parent_logical_state = CheckState.INDETERMINATE
	elif first_child_state != -1: new_parent_logical_state = first_child_state
	else: new_parent_logical_state = CheckState.UNCHECKED

	var meta: Dictionary = item.get_metadata(0)
	if not meta is Dictionary:
		meta = {}
	meta[META_STATE] = new_parent_logical_state
	item.set_metadata(0, meta)

	match new_parent_logical_state:
		CheckState.UNCHECKED: item.set_checked(0, false); item.set_indeterminate(0, false)
		CheckState.CHECKED: item.set_checked(0, true); item.set_indeterminate(0, false)
		CheckState.INDETERMINATE: item.set_checked(0, false); item.set_indeterminate(0, true)


# --- Icon and Preview Logic ---
func _on_preview_ready(path_arg: String, preview_texture: Texture2D, thumbnail_texture: Texture2D, userdata: Dictionary) -> void:
	var expected_path: String = userdata.get(META_PATH, "")
	if not expected_path in preview_requests:
		return
	var item: TreeItem = preview_requests.get(expected_path)
	if not is_instance_valid(item):
		preview_requests.erase(expected_path)
		return
	preview_requests.erase(expected_path)

	var final_texture_to_use: Texture2D = null
	if is_instance_valid(thumbnail_texture):
		final_texture_to_use = thumbnail_texture
	elif is_instance_valid(preview_texture):
		final_texture_to_use = preview_texture

	if is_instance_valid(final_texture_to_use):
		item.set_icon(0, final_texture_to_use)


func _get_icon_for_file_fallback(extension: String) -> Texture2D:
	if has_theme_icon(extension.capitalize(), &"EditorIcons"):
		return get_theme_icon(extension.capitalize(), &"EditorIcons")

	match extension:
		"gd": return get_theme_icon(&"GDScript", &"EditorIcons")
		"tscn", "scn": return get_theme_icon(&"PackedScene", &"EditorIcons")
		"tres", "res": return get_theme_icon(&"Resource", &"EditorIcons")
		"txt", "md", "cfg", "ini", "json", "xml", "toml", "log", "csv", "yaml", "yml", "url", "mtl": return get_theme_icon(&"TextFile", &"EditorIcons")
		"godot", "project": return get_theme_icon(&"Godot", &"EditorIcons")
		"wav", "ogg", "mp3": return get_theme_icon(&"AudioStream", &"EditorIcons")
		"shader", "gdshader", "gdshaderinc": return get_theme_icon(&"Shader", &"EditorIcons")
		"glb", "gltf": return get_theme_icon(&"PackedScene", &"EditorIcons")
		"obj", "fbx", "dae": return get_theme_icon(&"Mesh", &"EditorIcons")
		"zip", "gz", "rar", "7z": return get_theme_icon(&"Zip", &"EditorIcons")
		"svg", "png", "jpg", "jpeg", "webp", "tga", "bmp", "exr", "hdr": return get_theme_icon(&"ImageTexture", &"EditorIcons")
		"ttf", "otf", "woff", "woff2": return get_theme_icon(&"Font", &"EditorIcons")
		"import": return get_theme_icon(&"Import", &"EditorIcons")
		"material": return get_theme_icon(&"Material", &"EditorIcons")
		"env", "environment": return get_theme_icon(&"Environment", &"EditorIcons")
		"mesh": return get_theme_icon(&"Mesh", &"EditorIcons")
		_: return get_theme_icon(&"Object", &"EditorIcons")


# <<< AÑADIDO >>> Nueva función para manejar clics de ratón
# --- Manejo Clic Derecho para Navegación ---
func _on_item_mouse_selected(position: Vector2, mouse_button_index: int) -> void:
	# Solo actuar con el clic derecho
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		var item: TreeItem = get_item_at_position(position)
		if not is_instance_valid(item):
			printerr("CopyContextAI: No valid item found at right-click position.")
			return

		var meta: Dictionary = item.get_metadata(0)
		if not meta is Dictionary or not meta.has(META_PATH):
			printerr("CopyContextAI: Right-clicked item missing metadata or path.")
			return

		var path: String = meta.get(META_PATH, "")
		if path.is_empty() or not path.begins_with("res://"):
			printerr("CopyContextAI: Invalid path in item metadata for navigation: ", path)
			return

		# Intentar obtener el sistema de archivos del editor (solo disponible en el editor)
		if Engine.is_editor_hint():
			var efs: EditorFileSystem = EditorInterface.get_resource_filesystem()
			if efs:
				print("CopyContextAI: Navigating FileSystem dock to: ", path)
				efs.navigate_to_path(path)
				# Marcar el evento como manejado para evitar el menú contextual del Tree
				get_viewport().set_input_as_handled()
			else:
				printerr("CopyContextAI: Could not get EditorFileSystem to navigate.")
		else:
			printerr("CopyContextAI: Navigation only works inside the Godot Editor.")

	# Ignorar clic izquierdo aquí (se maneja en _on_item_edited para el checkbox)
	elif mouse_button_index == MOUSE_BUTTON_LEFT:
		pass


# --- API for Copy/Paste Functionality ---
# (Funciones _build_context_recursive, get_context_data_for_xml, _get_file_content_as_cdata sin cambios)
func _build_context_recursive(item: TreeItem, indent: String, lines: PackedStringArray, details: Array) -> void:
	if not is_instance_valid(item):
		return
	var meta: Dictionary = item.get_metadata(0)
	if not meta is Dictionary:
		return

	var path: String = meta.get(META_PATH, "")
	var state: CheckState = meta.get(META_STATE, CheckState.UNCHECKED)
	var is_dir: bool = item.get_child_count() > 0 or (not path.is_empty() and DirAccess.dir_exists_absolute(path))

	var state_str: String
	match state:
		CheckState.UNCHECKED:
			state_str = "[ ]"
		CheckState.CHECKED:
			state_str = "[x]"
		CheckState.INDETERMINATE:
			state_str = "[-]"

	var structure_line: String = indent + state_str + " " + path
	lines.append(structure_line)

	if not _context_limit_reached:
		_current_context_chars += structure_line.length() + 1 # +1 for newline
		if _current_context_chars > MAX_CONTEXT_CHARS:
			_context_limit_reached = true
			printerr("CopyContextAI: Context character limit (%d) reached during FileStructure generation." % MAX_CONTEXT_CHARS)

	if not is_dir and (state == CheckState.CHECKED or state == CheckState.INDETERMINATE):
		if not path.is_empty():
			var detail_to_add: Dictionary = {"path": path, "state": state_str, "content_cdata": ""}
			var extension: String = path.get_extension().to_lower()
			var is_text_file: bool = extension in TEXT_EXTENSIONS
			var content_to_add: String = ""
			var length_of_content_to_add: int = 0
			var should_attempt_read: bool = true
			var is_placeholder: bool = false

			if _context_limit_reached:
				content_to_add = _limit_reached_before_message
				should_attempt_read = false
				is_placeholder = true
			elif _current_context_chars + FILE_DETAIL_TAG_OVERHEAD > MAX_CONTEXT_CHARS:
				content_to_add = _limit_reached_message
				_context_limit_reached = true
				should_attempt_read = false
				is_placeholder = true
			elif not is_text_file:
				content_to_add = _non_text_omitted_message
				should_attempt_read = false
				is_placeholder = true
			elif state == CheckState.CHECKED:
				if not FileAccess.file_exists(path):
					content_to_add = _file_not_found_message
					should_attempt_read = false
					is_placeholder = true
				else:
					var temp_file: FileAccess = FileAccess.open(path, FileAccess.READ)
					if not temp_file:
						content_to_add = _read_error_message + " (Size Check)"
						should_attempt_read = false
						is_placeholder = true
					else:
						var file_size: int = temp_file.get_length()
						temp_file.close()
						if _current_context_chars + file_size + FILE_DETAIL_TAG_OVERHEAD > MAX_CONTEXT_CHARS:
							content_to_add = _limit_reached_message
							_context_limit_reached = true
							should_attempt_read = false
							is_placeholder = true
							printerr("CopyContextAI: Limit reached. Omitting [x]: %s (Size: %d)" % [path, file_size])

			if should_attempt_read:
				content_to_add = _get_file_content_as_cdata(path, state)
				if content_to_add.begins_with("--- (Error:"):
					is_placeholder = true
				else:
					length_of_content_to_add = content_to_add.length()
					if _current_context_chars + length_of_content_to_add + FILE_DETAIL_TAG_OVERHEAD > MAX_CONTEXT_CHARS:
						content_to_add = _limit_reached_message
						_context_limit_reached = true
						is_placeholder = true
						printerr("CopyContextAI: Limit reached after reading: %s" % [path])

			detail_to_add["content_cdata"] = content_to_add
			length_of_content_to_add = content_to_add.length()
			if content_to_add != _limit_reached_before_message:
				if not _context_limit_reached and _current_context_chars + length_of_content_to_add + FILE_DETAIL_TAG_OVERHEAD <= MAX_CONTEXT_CHARS:
					_current_context_chars += length_of_content_to_add + FILE_DETAIL_TAG_OVERHEAD
				elif not _context_limit_reached:
					_context_limit_reached = true
					detail_to_add["content_cdata"] = _limit_reached_message
					printerr("CopyContextAI: Limit reached even for placeholder: %s" % [path])

			details.append(detail_to_add)

	var child: TreeItem = item.get_first_child()
	while is_instance_valid(child):
		_build_context_recursive(child, indent + "  ", lines, details)
		child = child.get_next()


func get_context_data_for_xml() -> Dictionary:
	_current_context_chars = 0
	_context_limit_reached = false
	var structure_lines: PackedStringArray = []
	var details_list: Array[Dictionary] = []
	var root: TreeItem = get_root()
	if not is_instance_valid(root):
		printerr("CopyContextAI: Root invalid in get_context_data_for_xml.")
		return {"structure": "", "details": [], "status": "Error: Root invalid"}

	var initial_overhead: int = "<GodotContextOutput>\n<FileStructure>\n<![CDATA[\n".length() \
		+ "\n]]>\n</FileStructure>\n<FileDetails>\n".length() \
		+ "\n</FileDetails>\n</GodotContextOutput>".length()
	_current_context_chars += initial_overhead

	_build_context_recursive(root, "", structure_lines, details_list)

	var path_sorter: Callable = func(a: Dictionary, b: Dictionary) -> bool : return a.path < b.path
	details_list.sort_custom(path_sorter)

	var structure_cdata: String = "\n".join(structure_lines)
	var final_status: String = "OK"
	if _context_limit_reached:
		final_status = "Truncated (limit approx. %d chars)" % MAX_CONTEXT_CHARS
		print("CopyContextAI: Context generated, but truncated.")

	print("CopyContextAI: Final context chars (approx): %d / %d" % [_current_context_chars, MAX_CONTEXT_CHARS])
	return {"structure": structure_cdata, "details": details_list, "status": final_status}


func _get_file_content_as_cdata(path: String, state: CheckState) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return _read_error_message + " (%s)" % error_string(FileAccess.get_open_error())

	var content: String = ""
	var error_during_read: bool = false

	if state == CheckState.CHECKED:
		content = file.get_as_text()
		if file.get_error() != OK:
			printerr("CopyContextAI: Error get_as_text for %s" % path)
			content = _read_error_message + " (Post Read)"
			error_during_read = true
	else: # Resumen para [-]
		var lines_read: Array[String] = []
		var line_count: int = 0
		while not file.eof_reached() and line_count < MAX_SUMMARY_LINES:
			if file.get_error() != OK:
				printerr("CopyContextAI: Error reading line %d from %s" % [line_count + 1, path])
				content = _read_error_message + " (Read Line)"
				error_during_read = true
				break
			# Check eof again after potential error
			if file.eof_reached():
				break
			lines_read.append(file.get_line())
			line_count += 1

		if not error_during_read:
			content = "\n".join(lines_read)
			var eof_after_summary: bool = file.eof_reached()
			var info_suffix: String = ""
			if line_count == 0 and eof_after_summary:
				info_suffix = "\n--- (File is empty) ---"
			elif not eof_after_summary:
				info_suffix = "\n--- (Showing first %d lines; more lines exist) ---" % line_count
			elif eof_after_summary: # Reached eof exactly at MAX_SUMMARY_LINES or before
				info_suffix = "\n--- (Showing all %d lines) ---" % line_count
			content += info_suffix

	file.close()

	# Escapar ']]>' si aparece en el contenido
	if not error_during_read:
		content = content.replace("]]>", "]]>]]><![CDATA[") # Standard conformant way

	return content


# --- Simplified File System Modifications ---
# (Funciones execute_modifications_simple, _apply_*, sin cambios)
func execute_modifications_simple(operations: Array) -> bool:
	if operations.is_empty():
		print("CopyContextAI: No file modifications requested.")
		return false

	var change_attempted: bool = false
	var any_change_succeeded: bool = false
	print("CopyContextAI: Attempting %d file modification(s)..." % operations.size())

	for op in operations:
		change_attempted = true
		var success: bool = false
		var op_type: String = op.get("type", "")

		var path: String = op.get("path", "")
		var old_path: String = op.get("oldPath", "")
		var new_path: String = op.get("newPath", "")
		var content: String = op.get("content", "")

		match op_type:
			"replace":
				success = _apply_replace_content(path, content)
			"create":
				success = _apply_create_file(path, content)
			"delete":
				success = _apply_delete_item(path)
			"rename":
				success = _apply_rename_item(old_path, new_path)
			"patch":
				success = _apply_patch(path, content)
			_:
				printerr("CopyContextAI: Unknown modification type: ", op_type)

		if success:
			any_change_succeeded = true

	return change_attempted and any_change_succeeded


func _apply_replace_content(path: String, content: String) -> bool:
	if path.is_empty() or not path.begins_with("res://"):
		printerr("CopyContextAI: Replace Error: Invalid path '%s'." % path)
		return false
	var dir_path: String = path.get_base_dir()
	var dir_err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		printerr("CopyContextAI: Replace Error: Failed dir '%s': %s" % [dir_path, dir_err])
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		print("CopyContextAI: Replaced: ", path)
		return true
	else:
		printerr("CopyContextAI: Replace Error: Failed write open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false


func _apply_create_file(path: String, content: String) -> bool:
	if path.is_empty() or not path.begins_with("res://"):
		printerr("CopyContextAI: Create Error: Invalid path '%s'." % path)
		return false
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		printerr("CopyContextAI: Create Error: Path '%s' exists." % path)
		return false
	var dir_path: String = path.get_base_dir()
	var err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK and err != ERR_ALREADY_EXISTS:
		printerr("CopyContextAI: Create Error: Failed dir '%s': %s" % [dir_path, err])
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		print("CopyContextAI: Created: ", path)
		return true
	else:
		printerr("CopyContextAI: Create Error: Failed write open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false


func _apply_delete_item(path: String) -> bool:
	if path.is_empty() or not path.begins_with("res://") or path == "res://":
		printerr("CopyContextAI: Delete Error: Invalid path '%s'." % path)
		return false
	var exists: bool = DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path)
	if not exists:
		printerr("CopyContextAI: Delete Warning: Path '%s' not found." % path)
		return true # Treat as success if already gone
	var err: Error = DirAccess.remove_absolute(path)
	if err == OK:
		print("CopyContextAI: Deleted: ", path)
		return true
	else:
		printerr("CopyContextAI: Delete Error: Failed delete '%s': %s" % [path, err])
		return false


func _apply_rename_item(old_path: String, new_path: String) -> bool:
	if old_path.is_empty() or not old_path.begins_with("res://") or \
	   new_path.is_empty() or not new_path.begins_with("res://") or \
	   old_path == new_path:
		printerr("CopyContextAI: Rename Error: Invalid paths '%s' -> '%s'." % [old_path, new_path])
		return false
	if not DirAccess.dir_exists_absolute(old_path) and not FileAccess.file_exists(old_path):
		printerr("CopyContextAI: Rename Error: Source '%s' not found." % old_path)
		return false
	if DirAccess.dir_exists_absolute(new_path) or FileAccess.file_exists(new_path):
		printerr("CopyContextAI: Rename Error: Target '%s' exists." % new_path)
		return false
	var new_dir: String = new_path.get_base_dir()
	var err: Error = DirAccess.make_dir_recursive_absolute(new_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		printerr("CopyContextAI: Rename Error: Failed target dir '%s': %s" % [new_dir, err])
		return false
	err = DirAccess.rename_absolute(old_path, new_path)
	if err == OK:
		print("CopyContextAI: Renamed: %s -> %s" % [old_path, new_path])
		return true
	else:
		printerr("CopyContextAI: Rename Error: Failed rename '%s' to '%s': %s" % [old_path, new_path, err])
		return false


func _apply_patch(path: String, diff_content: String) -> bool:
	if path.is_empty() or not path.begins_with("res://"):
		printerr("CopyContextAI: Patch Error: Invalid path."); return false
	if diff_content.is_empty():
		printerr("CopyContextAI: Patch Error: Diff empty."); return false
	if not FileAccess.file_exists(path):
		printerr("CopyContextAI: Patch Error: File not exist."); return false

	var file_read: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file_read:
		printerr("CopyContextAI: Patch Error: Failed read open."); return false
	var original_content: String = file_read.get_as_text().replace("\r\n", "\n") # Normalize
	var read_err: Error = file_read.get_error()
	file_read.close()
	if read_err != OK:
		printerr("CopyContextAI: Patch Error: Failed read content."); return false

	var search_marker: String = "<<<<<<< SEARCH"
	var separator_marker: String = "======="
	var replace_marker: String = ">>>>>>> REPLACE"

	var search_start_idx: int = diff_content.find(search_marker)
	if search_start_idx == -1:
		printerr("CopyContextAI: Patch Error: '%s' not found." % search_marker); return false
	var separator_idx: int = diff_content.find(separator_marker, search_start_idx + search_marker.length())
	if separator_idx == -1:
		printerr("CopyContextAI: Patch Error: '%s' not found after SEARCH." % separator_marker); return false
	var replace_end_idx: int = diff_content.find(replace_marker, separator_idx + separator_marker.length())
	if replace_end_idx == -1:
		printerr("CopyContextAI: Patch Error: '%s' not found after SEPARATOR." % replace_marker); return false

	# Extract SEARCH block (v4 logic)
	var search_line_end_idx: int = diff_content.find("\n", search_start_idx)
	if search_line_end_idx == -1: search_line_end_idx = search_start_idx + search_marker.length()
	else: search_line_end_idx += 1
	var raw_search_block: String = diff_content.substr(search_line_end_idx, separator_idx - search_line_end_idx)
	while raw_search_block.ends_with("\n") or raw_search_block.ends_with("\r"): raw_search_block = raw_search_block.substr(0, raw_search_block.length() - 1)
	var search_block: String = raw_search_block.replace("\r\n", "\n")

	# Extract REPLACE block (v4 logic)
	var replace_line_end_idx: int = diff_content.find("\n", separator_idx)
	if replace_line_end_idx == -1: replace_line_end_idx = separator_idx + separator_marker.length()
	else: replace_line_end_idx += 1
	var raw_replace_block: String = diff_content.substr(replace_line_end_idx, replace_end_idx - replace_line_end_idx)
	while raw_replace_block.ends_with("\n") or raw_replace_block.ends_with("\r"): raw_replace_block = raw_replace_block.substr(0, raw_replace_block.length() - 1)
	var replace_block: String = raw_replace_block.replace("\r\n", "\n")

	# Find normalized block in normalized content
	var found_at: int = original_content.find(search_block)
	if found_at == -1:
		printerr("CopyContextAI: Patch Error: NORMALIZED SEARCH block not found exactly in '%s'." % path)
		# Optional: Add debug prints here if needed
		# print("Normalized Expected SEARCH (escaped): ", search_block.c_escape())
		# print("Normalized Original Content (escaped): ", original_content.c_escape())
		return false

	# Optional: Warn about multiple occurrences
	var second_found_at: int = original_content.find(search_block, found_at + 1)
	if second_found_at != -1 and second_found_at > found_at :
		print("CopyContextAI: Patch Warning: SEARCH found multiple times. Applied only at %d." % found_at)

	# Build new content
	var prefix: String = original_content.substr(0, found_at)
	var suffix: String = original_content.substr(found_at + search_block.length())
	var new_content: String = prefix + replace_block + suffix

	# Write new content
	var file_write: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not file_write:
		printerr("CopyContextAI: Patch Error: Failed write open '%s': %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	file_write.store_string(new_content)
	var write_err: Error = file_write.get_error()
	file_write.close()
	if write_err != OK:
		printerr("CopyContextAI: Patch Error: Failed write content '%s': %s" % [path, write_err])
		return false

	print("CopyContextAI: Successfully patched: ", path)
	return true


# --- Context Application ---
# (apply_context_command sin cambios)
func apply_context_command(commands: Dictionary, reset_first: bool = true) -> void:
	if not is_instance_valid(get_root()):
		printerr("CopyContextAI: FileTree: Root invalid.")
		return
	var was_handling: bool = _is_handling_edit
	_is_handling_edit = true
	if reset_first:
		print("CopyContextAI: Resetting tree state.")
		_set_item_state_recursive(get_root(), CheckState.UNCHECKED)

	var sorted_paths: Array = commands.keys()
	sorted_paths.sort()

	for path in sorted_paths:
		var state_enum: int = commands[path]
		var item: TreeItem = _get_item_by_path(path)
		if is_instance_valid(item):
			var meta: Dictionary = item.get_metadata(0)
			if not meta is Dictionary:
				meta = {}
			if state_enum in CheckState.values():
				meta[META_STATE] = state_enum
				item.set_metadata(0, meta)
				match state_enum:
					CheckState.UNCHECKED:
						item.set_checked(0, false); item.set_indeterminate(0, false)
					CheckState.CHECKED:
						item.set_checked(0, true); item.set_indeterminate(0, false)
					CheckState.INDETERMINATE:
						item.set_checked(0, false); item.set_indeterminate(0, true)
			else:
				printerr("CopyContextAI: Invalid state value '%s' for path '%s'." % [state_enum, path])
		else:
			print("CopyContextAI: Path '%s' from SetContext not found." % path)

	_update_all_folder_states()
	_is_handling_edit = was_handling
	print("CopyContextAI: Context applied from command.")


# --- Tree Refresh ---
# (refresh_tree sin cambios)
func refresh_tree() -> void:
	print("CopyContextAI: Refreshing FileTree...")
	populate_tree()


# --- Utility ---
# (_get_item_by_path sin cambios)
func _get_item_by_path(path: String) -> TreeItem:
	return _path_to_item_lookup.get(path, null)


# --- Funciones Antiguas ---
# (Omitidas: _get_checked_items_recursive, get_selected_paths, get_selected_contents)
