#> shot("07-dashboard--step2")
import retroui

let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
let sales = @[12.0, 15.5, 14.2, 18.9, 21.3, 24.0]
let costs = @[9.0, 10.5, 11.0, 12.2, 13.0, 13.4]

app "Sales", 520, 345:
  lineChart([sales, costs], months, names = ["Sales", "Costs"], title = "Thousands, OMR")
  barChart(sales, months, h = dp(110))
