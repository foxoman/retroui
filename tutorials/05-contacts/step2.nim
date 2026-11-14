#> clickMark(0)
#> shot("05-contacts--step2")
import retroui

type
  Kind = enum Family, Friend, Work
  Contact = object
    fullName {.required, maxLen: 40.}: string
    phone: string
    kind: Kind
    favourite: bool

var draft = Contact(fullName: "Salim Al Harthy", phone: "+968 9555 0101", kind: Work)
var book = @[Contact(fullName: "Maryam Al Balushi", phone: "+968 9123 4567", kind: Friend,
                     favourite: true)]
var sel = 0

app "Contacts", 480, 380:
  formOf(draft, labelW = 80)
  if button("&Add", enabled = formValid(draft)):   # grayed until the form is right
    book.add draft
    draft = Contact()
  mark "add"
  gridOf(book, sel, height = 4)      # a column for each field; a header's click sorts
