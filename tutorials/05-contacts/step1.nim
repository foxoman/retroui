#> shot("05-contacts--step1")
import retroui

type
  Kind = enum Family, Friend, Work
  Contact = object
    fullName {.required, maxLen: 40.}: string
    phone {.help: "With the country's code: +968...".}: string
    kind: Kind
    birthday: Date
    favourite: bool

var c = Contact(fullName: "Maryam Al Balushi", phone: "+968 9123 4567", kind: Friend,
                birthday: Date(year: 1994, month: 3, day: 21))

app "Contact", 380, 230:
  formOf(c)                          # a field for each field of Contact
