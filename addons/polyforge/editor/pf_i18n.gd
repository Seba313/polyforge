## PfI18n — Polyforge UI translations, following the editor language.
## Catalogs: addons/polyforge/i18n/<lang>.po (msgid = English text). Missing
## language or entry -> English. Blender-style names stay consistent because
## Polyforge's own controls are never auto-translated by the editor.
@tool
extends RefCounted

const DIR := "res://addons/polyforge/i18n/"

static var _tr: Translation = null
static var _loaded := false

static func t(s: String) -> String:
	if not _loaded:
		_load()
	if _tr == null or s.is_empty():
		return s
	var r := String(_tr.get_message(s))
	return r if not r.is_empty() else s

static func _load() -> void:
	_loaded = true
	var lang := str(EditorInterface.get_editor_settings().get_setting("interface/editor/editor_language"))
	for code in [lang, lang.get_slice("_", 0)]:
		if ResourceLoader.exists(DIR + code + ".po"):
			_tr = load(DIR + code + ".po")
			return

## Translates texts, tooltips, menu items and titles of `n` and its children
## (internal ones too, e.g. a MenuButton's popup).
static func localize(n: Node) -> void:
	if n is OptionButton:
		for i in n.item_count:
			n.set_item_text(i, t(n.get_item_text(i)))
	elif n is Button:
		n.text = t(n.text)
	elif n is Label:
		n.text = t(n.text)
	elif n is LineEdit:
		n.placeholder_text = t(n.placeholder_text)
	if n is Control:
		n.tooltip_text = t(n.tooltip_text)
	if n is PopupMenu:
		for i in n.item_count:
			n.set_item_text(i, t(n.get_item_text(i)))
			n.set_item_tooltip(i, t(n.get_item_tooltip(i)))
	if n is Window:
		n.title = t(n.title)
	for c in n.get_children(true):
		localize(c)
