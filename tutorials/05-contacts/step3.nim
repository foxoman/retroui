#> clickMark(0)
#> key(KeyE, {AltPressed})
#> shot("05-contacts--step3")
import retroui

type Contact = object
  fullName {.required.}: string
  phone: string

var draft = Contact(fullName: "Aisha Al Said", phone: "+968 9777 2020")
var book = @[Contact(fullName: "Maryam Al Balushi", phone: "+968 9123 4567")]
var sel = 0
var history: UndoStack               # the changes, to take back

app "Contacts", 420, 300:
  menubar:
    menu "&Edit":
      undoMenuItems(history)         # "Undo Add", grayed when there is nothing
  formOf(draft, labelW = 80)
  if button("&Add", enabled = formValid(draft)):
    let before = book
    book.add draft
    history.record("Add", book, before)   # Undo puts `before` back
    draft = Contact()
  mark "add"
  gridOf(book, sel, height = 3)
  undoKeys(history)                  # Ctrl+Z and Ctrl+Y, after the text boxes
