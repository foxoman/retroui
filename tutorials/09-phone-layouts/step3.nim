#> shot("09-phone-layouts--step3")
#> phone(300, 300)
#> shot("09-phone-layouts--step3-phone")
import retroui

var name = "Maryam"
var city = 1
var agree = true

app "Sign up", 460, 160:
  form 90:                           # captions beside the fields; above them on a phone
    field "&Name:": edit name
    field "&City:": combo(["Muscat", "Sohar", "Salalah"], city)
    field "": checkbox("&Send me the news", agree)
  if isCompact():                    # a phone: one big button across
    button("Sign up", isDefault = true)
  else:
    row:
      spring()
      button("Sign up", isDefault = true)
      button("Cancel")
