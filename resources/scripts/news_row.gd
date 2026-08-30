extends PanelContainer

@onready var title_link: LinkButton = $MarginContainer/VBoxContainer/NewsTitle
@onready var date_label: Label = $MarginContainer/VBoxContainer/NewsDate
@onready var desc_label: RichTextLabel = $MarginContainer/VBoxContainer/NewsDescription

var article_link: String = ""

func setup(title: String, link: String, date: String, desc: String) -> void:
	title_link.text = title
	date_label.text = date
	desc_label.text = desc
	article_link = link
	
	# Connect the title link directly to the OS shell open command
	title_link.pressed.connect(_on_link_pressed)

func _on_link_pressed() -> void:
	if article_link != "":
		OS.shell_open(article_link)
