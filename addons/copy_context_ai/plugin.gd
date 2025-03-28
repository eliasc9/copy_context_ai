@tool
extends EditorPlugin

var main_panel_instance

const MainPanelScene = preload("res://addons/copy_context_ai/copy_context_ai.tscn")

func _enter_tree():
	main_panel_instance = MainPanelScene.instantiate()
	add_control_to_dock(DOCK_SLOT_LEFT_BR, main_panel_instance)

func _exit_tree():
	if main_panel_instance:
		remove_control_from_docks(main_panel_instance)
		main_panel_instance.queue_free()
		main_panel_instance = null
