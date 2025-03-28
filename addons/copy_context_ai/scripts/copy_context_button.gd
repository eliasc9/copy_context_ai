# copy_context_button.gd
@tool
extends Button

@export var file_tree: Tree = null
@export var include_sysprompt_checkbox: CheckBox = null # <-- Export for Checkbox

const SYSPROMPT_FILE_PATH = "res://addons/copy_context_ai/scripts/copy_sysprompt_content.md"

func _ready():
	if not is_connected("pressed", Callable(self, "_on_pressed")):
		connect("pressed", Callable(self, "_on_pressed"))
	
	if Engine.is_editor_hint():
		icon = get_theme_icon("ActionCopy", "EditorIcons")

func _on_pressed():
	if not Engine.is_editor_hint(): return

	# --- Verify Dependencies ---
	if not is_instance_valid(file_tree) or not file_tree.has_method("get_context_data_for_xml"):
		printerr("CopyContextAI (CopyButton): FileTree node invalid or method missing.")
		return
	# Verify Checkbox reference (CRITICAL for new logic)
	if not is_instance_valid(include_sysprompt_checkbox):
		printerr("CopyContextAI (CopyButton): IncludeSyspromptCheckbox node invalid or not assigned in Inspector!")
		return # Cannot proceed without checkbox reference

	# --- Get Context Data ---
	var context_data: Dictionary = file_tree.get_context_data_for_xml()
	# Use helper to build XML (now includes CDATA fix)
	var context_xml_output: String = _build_context_xml(context_data)
	if context_xml_output.is_empty() and not context_data.is_empty():
		printerr("CopyContextAI (CopyButton): Failed to build context XML string.")
		# Allow empty if context data itself was empty/invalid
		context_xml_output = _build_context_xml({}) # Build minimal empty structure
	elif context_xml_output.is_empty():
		print("CopyContextAI (CopyButton): Context data seems empty, copying empty structure.")
		context_xml_output = _build_context_xml({}) # Build minimal empty structure


	# --- Check Checkbox State ---
	var include_sysprompt: bool = include_sysprompt_checkbox.button_pressed # Use button_pressed
	var final_clipboard_content: String = ""

	if include_sysprompt:
		# --- Include System Prompt ---
		var sysprompt_content: String = _get_sysprompt_content()
		if sysprompt_content.is_empty():
			printerr("CopyContextAI (CopyButton): Failed to read system prompt, copying context only.")
			final_clipboard_content = context_xml_output
			# Optional: Decide if checkbox should still be unchecked on prompt read failure
			# include_sysprompt_checkbox.button_pressed = false
		else:
			final_clipboard_content = sysprompt_content + "\n\n" + context_xml_output
			# --- Uncheck the box after successful combined copy ---
			include_sysprompt_checkbox.button_pressed = false
			print("CopyContextAI (CopyButton): Copied Sysprompt + Context. Checkbox unchecked.")
	else:
		# --- Copy Context Only ---
		final_clipboard_content = context_xml_output
		print("CopyContextAI (CopyButton): Copied Context only.")


	# --- Copy to Clipboard ---
	DisplayServer.clipboard_set(final_clipboard_content)


# --- Helper to read sysprompt ---
func _get_sysprompt_content() -> String:
	var file = FileAccess.open(SYSPROMPT_FILE_PATH, FileAccess.READ)
	if file:
		var content = file.get_as_text()
		file.close()
		return content
	else:
		printerr("CopyContextAI (CopyButton): Error opening system prompt file: %s. Error: %s" % [SYSPROMPT_FILE_PATH, error_string(FileAccess.get_open_error())])
		return "" # Return empty on error

# --- Helper to build context XML (with CDATA fix) ---
func _build_context_xml(context_data: Dictionary) -> String:
	if context_data.is_empty(): return "<GodotContextOutput>\n<FileStructure>\n<![CDATA[\n(No context selected or retrieved)\n]]>\n</FileStructure>\n<FileDetails />\n</GodotContextOutput>"

	var structure = context_data.get("structure", "(Error retrieving structure)")
	var details: Array = context_data.get("details", [])

	var xml_output = "<GodotContextOutput>\n"
	xml_output += "<FileStructure>\n<![CDATA[\n" + structure + "\n]]>\n</FileStructure>\n" # Correct CDATA
	xml_output += "<FileDetails>\n"

	for detail in details:
		var path = str(detail.get("path", "")).xml_escape()
		var state = str(detail.get("state", "[?]") ).xml_escape() # Use ? if state missing
		# Assumes content_cdata from file_tree.gd already handles internal ']]>' escaping
		var content = detail.get("content_cdata", "")

		xml_output += "<File path=\"%s\" state=\"%s\">\n" % [path, state]
		xml_output += "<![CDATA[\n"
		xml_output += content + "\n"
		xml_output += "]]>\n" # Correct CDATA closing
		xml_output += "</File>\n"

	xml_output += "</FileDetails>\n"
	xml_output += "</GodotContextOutput>"
	return xml_output
