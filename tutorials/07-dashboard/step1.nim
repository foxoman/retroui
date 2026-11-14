#> shot("07-dashboard--step1")
import retroui

app "Sales", 520, 240:
  kpiRow:
    statCard(pxChart, "Sales today", "OMR 1,240", "12 orders")
    statCard(pxUser, "New customers", "8", "3 from the website")
    kpiTile("Rooms taken", "86 %", delta = 0.04, deltaNote = "on last week")
