#> shot("f-typeform")
import retroui

type
  Shift = enum Morning, Evening, Night
  Person = object
    name {.caption: "Full name", required.}: string
    age {.limits: (16, 70).}: int
    shift: Shift
    remote: bool

var person = Person(name: "Maryam", age: 15)

app "Staff", 360, 205:
  formOf(person)                             # a field for each field; what is wrong under it
  if button("&Add", enabled = formValid(person)): discard
