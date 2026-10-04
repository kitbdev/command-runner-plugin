# Command Runner Plugin for Godot

Adds a dock to run expressions in the editor.
Used to manipulate the parts of the editor or the running project for debugging.

Use to:
Get and set values on any object.
Open a new floating inspector `inspect <object>`.
Monitor a signal and print when it is emitted. `track <signal name>`.
Reload a plugin `reload <plugin dir name>`.
Run commands on the running game instance `r sel.name`. Where `sel` is the selected remote node in the inspector.
Do math like any other expression.
etc


Temporary variables can be saved between commands `var <name> <value>` or `new <name> <classname>` to set, and it will be available in future commands.
Can be used with EditorDebugger to get parts of the editor more easily. https://github.com/Zylann/godot_editor_debugger_plugin
Command history is saved. Use up/down to see other entries. It persists between closing the editor of the same project.
Code completion support. You may need to add more lines (ctrl+enter) since it currently cannot show outside the CodeEdit.
New commands can be added by adding a function to the `custom_commands.gd` file following the format.
