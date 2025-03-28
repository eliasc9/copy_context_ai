# copy_context_ai.gd
# Script attached to the root node 'CopyContextAI' in copy_context_ai.tscn
@tool
extends Control

# --- EXPORTED VARIABLES (MUST BE ASSIGNED IN GODOT INSPECTOR) ---
# Assign the corresponding nodes from your scene tree to these slots in the Inspector.
@export var file_tree: Tree = null
@export var include_sysptompt_checkbox: CheckBox = null
@export var copy_context_button: Button = null
@export var paste_request_button: Button = null

# --- Lifecycle and Input ---

func _ready():
	call_deferred("_initialize_plugin")

func _initialize_plugin():
	# This function runs only in the Godot Editor
	if not Engine.is_editor_hint():
		queue_free() # Remove this control if running in a game build
		return

	# --- Verify Inspector Assignments ---
	# Check if the crucial nodes were assigned via the @export vars in the Inspector.
	var initialization_ok = true
	if not is_instance_valid(file_tree):
		printerr("CopyContextAI: CRITICAL ERROR - 'file_tree' export var is not assigned in the Inspector!")
		initialization_ok = false
	if not is_instance_valid(include_sysptompt_checkbox):
		# This button doesn't strictly NEED the file_tree, but check if it exists
		printerr("CopyContextAI: WARNING - 'include_sysptompt_checkbox' export var is not assigned in the Inspector!")
		# initialization_ok = false # Decide if this is critical
	if not is_instance_valid(copy_context_button):
		printerr("CopyContextAI: CRITICAL ERROR - 'copy_context_button' export var is not assigned in the Inspector!")
		initialization_ok = false
	if not is_instance_valid(paste_request_button):
		printerr("CopyContextAI: CRITICAL ERROR - 'paste_request_button' export var is not assigned in the Inspector!")
		initialization_ok = false

	if not initialization_ok:
		printerr("CopyContextAI: Initialization failed due to unassigned export variables. Check the Inspector for the CopyContextAI node.")
		return # Stop initialization if core components are missing

	# --- Assign FileTree Reference to Button Scripts ---
	# Pass the file_tree reference to the scripts attached to the relevant buttons,
	# so they can interact with the tree.

	# Assign to Copy Context Button's script
	if is_instance_valid(copy_context_button) and copy_context_button.script != null:
		# Use 'in' operator to check if the property exists (correct way)
		if "file_tree" in copy_context_button:
			copy_context_button.file_tree = file_tree
			print("CopyContextAI: Assigned FileTree reference to CopyContextButton.")
		else:
			# This error means the script copy_context_button.gd is missing `export var file_tree`
			printerr("CopyContextAI: ERROR - CopyContextButton script missing 'file_tree' export var.")
			initialization_ok = false # Mark as failed if assignment isn't possible
	else:
		# This error means either the button wasn't assigned in Inspector or has no script
		printerr("CopyContextAI: Failed to prepare CopyContextButton (check Inspector assignment and script attachment).")
		initialization_ok = false # Mark as failed

	# Assign to Paste Request Button's script
	if is_instance_valid(paste_request_button) and paste_request_button.script != null:
		# Use 'in' operator to check if the property exists (correct way)
		if "file_tree" in paste_request_button:
			paste_request_button.file_tree = file_tree
			print("CopyContextAI: Assigned FileTree reference to PasteRequestButton.")
		else:
			# This error means the script paste_request_button.gd is missing `export var file_tree`
			printerr("CopyContextAI: ERROR - PasteRequestButton script missing 'file_tree' export var.")
			initialization_ok = false # Mark as failed
	else:
		# This error means either the button wasn't assigned in Inspector or has no script
		printerr("CopyContextAI: Failed to prepare PasteRequestButton (check Inspector assignment and script attachment).")
		initialization_ok = false # Mark as failed


	# --- Final Status Message ---
	if initialization_ok:
		print("CopyContextAI: Plugin Initialized Successfully.")
	else:
		printerr("CopyContextAI: Initialization completed with errors. Check previous messages.")

	# NOTE: Signal connections ('pressed') for the buttons should be done
	# either directly in the Godot Editor (Inspector > Node > Signals)
	# or within the _ready() function of EACH button's respective script.
	# This script no longer handles those connections directly.


# Handle GUI input events for keyboard shortcuts (Ctrl+C, Ctrl+V)
func _gui_input(event: InputEvent):
	if not Engine.is_editor_hint(): return # Only active in editor

	if event is InputEventKey and event.pressed:
		# Check for Copy action (Ctrl+C or Cmd+C)
		if event.is_action("ui_copy", true):
			if has_focus_recursive(): # Check if focus is within this plugin's UI
				print("CopyContextAI: Ctrl+C detected with focus -> Triggering Copy Context Button")
				if is_instance_valid(copy_context_button):
					# Simulate clicking the Copy Context button
					copy_context_button.emit_signal("pressed")
				get_viewport().set_input_as_handled() # Prevent further processing of the event

		# Check for Paste action (Ctrl+V or Cmd+V)
		elif event.is_action("ui_paste", true):
			if has_focus_recursive(): # Check if focus is within this plugin's UI
				print("CopyContextAI: Ctrl+V detected with focus -> Triggering Paste Request Button")
				if is_instance_valid(paste_request_button):
					# Simulate clicking the Paste Request button
					paste_request_button.emit_signal("pressed")
				get_viewport().set_input_as_handled() # Prevent further processing of the event


# Helper function to determine if this control or any of its children
# (including the FileTree) currently have the GUI focus.
func has_focus_recursive() -> bool:
	var focused_control = get_viewport().gui_get_focus_owner()
	if focused_control == self: return true # Focus is on the root control itself
	if focused_control != null and is_ancestor_of(focused_control): return true # Focus is on a child/grandchild
	# Also specifically check if the FileTree itself has focus, as it might be complex
	if is_instance_valid(file_tree) and focused_control == file_tree: return true
	return false

# --- Button Action Handlers (_on_*_pressed) are NOT in this script anymore ---
# They reside within the individual button scripts (e.g., copy_context_button.gd).
