#> shot("05-contacts--step4")
import std/os
import retroui

type Contact = object
  fullName: string
  phone: string

var book = @[Contact(fullName: "Maryam Al Balushi", phone: "+968 9123 4567"),
             Contact(fullName: "Salim Al Harthy", phone: "+968 9555 0101")]
var sel = 0
var said = ""

app "Contacts", 420, 200:
  gridOf(book, sel, height = 3)
  row:
    if button("&Export CSV"):
      var t = DataTable(headers: @["Name", "Phone"])
      for c in book: t.rows.add @[c.fullName, c.phone]
      let path = dataDir("ContactsTutorial") / "contacts.csv"
      said = if writeCsv(path, t): "Saved " & path.extractFilename else: "Could not save"
    label said
