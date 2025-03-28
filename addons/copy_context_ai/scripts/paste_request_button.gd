# paste_request_button.gd
@tool
extends Button

@export var file_tree: Tree = null

# Estados simplificados para la sección general
enum SectionState {
	NONE, MODIFY_FILES, IN_REPLACE, IN_CREATE, IN_DELETE, IN_RENAME, IN_PATCH, SET_CONTEXT
}

func _ready():
	if not is_connected("pressed", Callable(self, "_on_pressed")):
		connect("pressed", Callable(self, "_on_pressed"))
	
	if Engine.is_editor_hint():
		icon = get_theme_icon("ActionPaste", "EditorIcons")

func _on_pressed():
	if not Engine.is_editor_hint(): return

	var clipboard_text: String = DisplayServer.clipboard_get()
	if clipboard_text.is_empty():
		printerr("CopyContextAI (PasteButton): Clipboard is empty."); return

	clipboard_text = clipboard_text.strip_edges()
	if not clipboard_text.begins_with("<GodotContextCommand>") or not clipboard_text.ends_with("</GodotContextCommand>"):
		printerr("CopyContextAI (PasteButton): Invalid command format: Missing root tags."); return

	var parser = XMLParser.new()
	var err = parser.open_buffer(clipboard_text.to_utf8_buffer())
	if err != OK:
		printerr("CopyContextAI (PasteButton): XML Parse Error: Failed open_buffer: %s" % err); return

	var operations: Array[Dictionary] = []
	var context_cdata: String = ""
	var current_section: SectionState = SectionState.NONE
	var current_file_op: Dictionary = {}
	var parse_error: bool = false

	# --- Bucle de Parseo v7 (Corregido con get_node_name() para CDATA) ---
	while not parse_error:
		err = parser.read() # Avanza al siguiente nodo

		if err == ERR_FILE_EOF: break # Fin normal
		if err != OK:
			var error_msg = parser.get_error_message()
			# Ya no filtramos el error != NODE_TEXT, ya que la causa era el uso incorrecto de get_node_data
			printerr("CopyContextAI (PasteButton): XML Parsing Error: %s at line %d" % [error_msg, parser.get_current_line()])
			parse_error = true; break # Abortar en errores

		var node_type = parser.get_node_type()

		match node_type:
			XMLParser.NODE_ELEMENT:
				var node_name: String = parser.get_node_name()
				var is_empty_element = parser.is_empty()

				match node_name:
					# Secciones Contenedoras
					"ModifyFiles": current_section = SectionState.MODIFY_FILES
					"ReplaceFiles": current_section = SectionState.IN_REPLACE
					"CreateFiles": current_section = SectionState.IN_CREATE
					"DeleteFiles": current_section = SectionState.IN_DELETE
					"RenameFiles": current_section = SectionState.IN_RENAME
					"PatchFiles": current_section = SectionState.IN_PATCH
					"SetContext": current_section = SectionState.SET_CONTEXT

					# Elementos de Operación que ESPERAN contenido si no son vacíos
					"File":
						if current_section == SectionState.IN_REPLACE or current_section == SectionState.IN_CREATE:
							var file_path = _get_attribute_or_error(parser, "path")
							if file_path.is_empty(): parse_error = true; break
							current_file_op = {"type": "replace" if current_section == SectionState.IN_REPLACE else "create", "path": file_path, "content": ""}
							if is_empty_element: operations.append(current_file_op); current_file_op = {}
						else: printerr("CopyContextAI (PasteButton): Unexpected <File> tag."); parse_error = true
					"Patch":
						if current_section == SectionState.IN_PATCH:
							var patch_path = _get_attribute_or_error(parser, "path")
							if patch_path.is_empty(): parse_error = true; break
							current_file_op = {"type": "patch", "path": patch_path, "content": ""}
							if is_empty_element:
								printerr("CopyContextAI (PasteButton): WARNING - Empty <Patch> tag for %s." % patch_path)
								operations.append(current_file_op); current_file_op = {}
						else: printerr("CopyContextAI (PasteButton): Unexpected <Patch> tag."); parse_error = true

					# Elementos de Operación que NO esperan contenido
					"Delete":
						if current_section == SectionState.IN_DELETE:
							var delete_path = _get_attribute_or_error(parser, "path")
							if delete_path.is_empty(): parse_error = true; break
							operations.append({"type": "delete", "path": delete_path})
						else: printerr("CopyContextAI (PasteButton): Unexpected <Delete> tag."); parse_error = true
					"Rename":
						if current_section == SectionState.IN_RENAME:
							var old_path = _get_attribute_or_error(parser, "oldPath")
							var new_path = _get_attribute_or_error(parser, "newPath")
							if old_path.is_empty() or new_path.is_empty(): parse_error = true; break
							operations.append({"type": "rename", "oldPath": old_path, "newPath": new_path})
						else: printerr("CopyContextAI (PasteButton): Unexpected <Rename> tag."); parse_error = true

			XMLParser.NODE_CDATA:
				# *** CORRECCIÓN: Usar get_node_name() para CDATA ***
				var data = parser.get_node_name() # <--- CAMBIO CLAVE
				# Acumular si estamos esperando contenido
				if not current_file_op.is_empty():
					# print("--> Acumulando CDATA para file_op: ", data.left(30)) # Debug
					current_file_op["content"] += data
				elif current_section == SectionState.SET_CONTEXT:
					# print("--> Acumulando CDATA para context: ", data.left(30)) # Debug
					context_cdata += data
				# else: print("--> Ignorando CDATA inesperado") # Debug

			XMLParser.NODE_TEXT:
				# *** Usar get_node_data() para TEXT ***
				var data = parser.get_node_data() # <--- Uso correcto para TEXT
				# Ignorar si es TEXT y solo whitespace, EXCEPTO para Patch
				if data.strip_edges().is_empty():
					if current_file_op.is_empty() or current_file_op.get("type") != "patch":
						# print("--> Ignorando TEXT whitespace") # Debug
						continue # Saltar este nodo

				# Acumular datos TEXT válidos
				if not current_file_op.is_empty():
					# print("--> Acumulando TEXT para file_op: ", data.left(30)) # Debug
					current_file_op["content"] += data
				elif current_section == SectionState.SET_CONTEXT:
					# print("--> Acumulando TEXT para context: ", data.left(30)) # Debug
					context_cdata += data
				# else: print("--> Ignorando TEXT inesperado") # Debug


			XMLParser.NODE_ELEMENT_END:
				var node_name: String = parser.get_node_name()

				match node_name:
					# Finalización de operaciones con contenido (<File> o <Patch>)
					"File", "Patch":
						if not current_file_op.is_empty():
							if node_name == "File": current_file_op["content"] = current_file_op["content"].strip_edges()
							operations.append(current_file_op)
							# print("--> Finalizada operacion: ", current_file_op) # Debug
							current_file_op = {} # Resetear
						# else: Era etiqueta vacía, ya procesada

					# Finalización de secciones contenedoras
					"ReplaceFiles", "CreateFiles", "DeleteFiles", "RenameFiles", "PatchFiles":
						current_section = SectionState.MODIFY_FILES
					"ModifyFiles":
						current_section = SectionState.NONE
					"SetContext":
						context_cdata = context_cdata.strip_edges()
						current_section = SectionState.NONE

			_: pass # Ignorar Comment, Unknown, None

	# --- Fin del Bucle ---
	parser = null

	if parse_error:
		printerr("CopyContextAI (PasteButton): Aborting due to XML parsing errors."); return

	# --- Verificación de FileTree y Ejecución (Sin cambios) ---
	if not is_instance_valid(file_tree):
		printerr("CopyContextAI (PasteButton): CRITICAL - FileTree instance is not valid."); return
	var can_modify = file_tree.has_method("execute_modifications_simple")
	var can_refresh = file_tree.has_method("refresh_tree")
	var can_apply_context = file_tree.has_method("apply_context_command")

	if not can_modify and not operations.is_empty(): printerr("CopyContextAI (PasteButton): WARNING - Missing 'execute_modifications_simple'. Modifications skipped.")
	if not can_refresh and not operations.is_empty(): printerr("CopyContextAI (PasteButton): WARNING - Missing 'refresh_tree'.")
	if not can_apply_context and not context_cdata.is_empty(): printerr("CopyContextAI (PasteButton): WARNING - Missing 'apply_context_command'. Context skipped.")

	# --- Ejecutar Modificaciones ---
	var needs_refresh = false
	if not operations.is_empty():
		if can_modify:
			print("CopyContextAI (PasteButton): Executing %d file modification(s)..." % operations.size())
			needs_refresh = file_tree.execute_modifications_simple(operations)
			if not needs_refresh and operations.size() > 0:
				print("CopyContextAI (PasteButton): Note: Modifications attempted, but none succeeded or required refresh.")
		# else: Advertencia ya mostrada

	# --- Refrescar Árbol ---
	if needs_refresh:
		if can_refresh:
			print("CopyContextAI (PasteButton): Refreshing tree after modification attempts.")
			await get_tree().process_frame
			file_tree.refresh_tree()
			await get_tree().process_frame
		# else: Advertencia ya mostrada

	# --- Aplicar Contexto ---
	if not context_cdata.is_empty():
		if can_apply_context:
			var context_commands = _parse_set_context_cdata(context_cdata)
			if not context_commands.is_empty():
				print("CopyContextAI (PasteButton): Applying new context settings.")
				if needs_refresh and can_refresh: await get_tree().process_frame
				file_tree.apply_context_command(context_commands, true)
			else:
				print("CopyContextAI (PasteButton): No valid context commands found in SetContext.")
		# else: Advertencia ya mostrada

	print("CopyContextAI (PasteButton): Paste Request processed.")


# --- Funciones Auxiliares (_get_attribute_or_error, _parse_set_context_cdata) ---
# (Sin cambios _get_attribute_or_error)
func _get_attribute_or_error(parser: XMLParser, attr_name: String) -> String:
	var value = ""
	var found = false
	var count = parser.get_attribute_count()
	for i in range(count):
		if parser.get_attribute_name(i) == attr_name:
			value = parser.get_attribute_value(i).strip_edges(); found = true; break
	if not found or value.is_empty():
		printerr("CopyContextAI (PasteButton): Required attribute '%s' missing/empty in node '%s' line %d." % [attr_name, parser.get_node_name(), parser.get_current_line()]); return ""
	if attr_name.ends_with("Path") and not value.begins_with("res://") and value != "res://":
		printerr("CopyContextAI (PasteButton): Invalid path for '%s': '%s'. Must start with 'res://'." % [attr_name, value]); return ""
	return value

# Helper para parsear CDATA de SetContext (CORREGIDO para ignorar comentarios '#')
func _parse_set_context_cdata(cdata: String) -> Dictionary:
	var commands = {}
	var state_unchecked = 0; var state_checked = 1; var state_indeterminate = 2;
	var lines = cdata.split("\n", false)
	for line in lines:
		var trimmed_line = line.strip_edges(); if trimmed_line.is_empty(): continue

		var state = -1; var path_with_comment = ""; var prefix_len = 0;
		if trimmed_line.begins_with("[ ] "): state = state_unchecked; prefix_len = 4
		elif trimmed_line.begins_with("[x] "): state = state_checked; prefix_len = 4
		elif trimmed_line.begins_with("[-] "): state = state_indeterminate; prefix_len = 4
		else: continue # Ignorar líneas sin prefijo de estado

		path_with_comment = trimmed_line.substr(prefix_len).strip_edges()

		# *** NUEVO: Separar el path del comentario ***
		var comment_start_index = path_with_comment.find("#")
		var path = ""
		if comment_start_index != -1:
			# Si hay un '#', tomar solo la parte anterior y quitar espacios
			path = path_with_comment.substr(0, comment_start_index).strip_edges()
		else:
			# Si no hay '#', usar la cadena completa
			path = path_with_comment

		# Validar el path extraído (sin el comentario)
		if path.begins_with("res://"):
			commands[path] = state
		elif not path.is_empty(): # No mostrar error si la línea solo contenía un comentario
			printerr("CopyContextAI (PasteButton): Invalid path found in SetContext CDATA (after removing comment): '%s'" % path)

	return commands
