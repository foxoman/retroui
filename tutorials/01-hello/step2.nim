#> clickMark(0)
#> key(KeyEnd)
#> typeText(" and Nim")
#> shot("01-hello--step2")
import retroui

var name = "World"                 # the state: a variable of your own

app "Hello", 300, 100:
  edit name                        # typing changes `name` at once
  mark "name"
  label "Hello, " & name & "!"     # drawn again each frame: always up to date
