@tool
extends EditorPlugin

var main_panel_instance
var _refresh_timer: Timer

const MainPanelScene = preload("res://addons/copy_context_ai/copy_context_ai.tscn")

func _enter_tree():
	main_panel_instance = MainPanelScene.instantiate()
	add_control_to_dock(DOCK_SLOT_LEFT_BR, main_panel_instance)

	# Timer para "debouncing" (evitar refrescos múltiples y muy seguidos)
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 0.5  # Espera medio segundo de inactividad antes de refrescar
	_refresh_timer.one_shot = true
	_refresh_timer.timeout.connect(_on_refresh_timer_timeout)
	main_panel_instance.add_child(_refresh_timer)

	# Conectar a la señal del sistema de archivos del editor
	var editor_filesystem = EditorInterface.get_resource_filesystem()
	if editor_filesystem and not editor_filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		editor_filesystem.filesystem_changed.connect(_on_filesystem_changed)
		print("CopyContextAI: Connected to filesystem changes.")

func _exit_tree():
	# Desconectar la señal para evitar errores al desactivar el plugin
	var editor_filesystem = EditorInterface.get_resource_filesystem()
	if editor_filesystem and editor_filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		editor_filesystem.filesystem_changed.disconnect(_on_filesystem_changed)
		print("CopyContextAI: Disconnected from filesystem changes.")

	if main_panel_instance:
		remove_control_from_docks(main_panel_instance)
		main_panel_instance.queue_free()
		main_panel_instance = null
	# El timer se libera junto con main_panel_instance

# Esta función se llama cada vez que hay un cambio en el sistema de archivos
func _on_filesystem_changed():
	# En lugar de refrescar inmediatamente, iniciamos (o reiniciamos) el temporizador.
	# Esto agrupa múltiples cambios rápidos (como al guardar una escena) en una sola actualización.
	_refresh_timer.start()

# Esta función se ejecuta cuando el temporizador termina
func _on_refresh_timer_timeout():
	if not is_instance_valid(main_panel_instance):
		return

	# Buscamos el nodo FileTree usando su nombre único
	var file_tree = main_panel_instance.find_child("FileTree", true, false) # Busca recursivamente
	if is_instance_valid(file_tree) and file_tree.has_method("refresh_tree"):
		print("CopyContextAI: Filesystem changed, refreshing tree...")
		file_tree.refresh_tree()
	else:
		printerr("CopyContextAI: Could not find FileTree node to refresh.")
