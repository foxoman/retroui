# Screen readers on Windows: UI Automation (what Narrator and NVDA read)
# finds the controls of tests/access/accesscheck.nim by name and kind, and
# presses its button through the Invoke pattern, as a screen reader does.
#
#   pwsh tests/access/windows.ps1        (after: nim c -o:build/accesscheck.exe tests/access/accesscheck.nim)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$T = [System.Windows.Automation.TreeScope]
$out = Join-Path $PWD "access.txt"
Remove-Item $out -ErrorAction SilentlyContinue
$env:RETRO_ACCESS_OUT = $out
$app = Start-Process -FilePath (Resolve-Path build/accesscheck.exe) -PassThru
$failed = 0
function Check($ok, $what) {
  if ($ok) { Write-Host "PASS $what" } else { Write-Host "FAIL $what"; $script:failed++ }
}
function Named($root, $name) {
  $c = New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name)
  for ($i = 0; $i -lt 60; $i++) {
    $e = $root.FindFirst($T::Descendants, $c)
    if ($e) { return $e }
    Start-Sleep -Milliseconds 250
  }
  return $null
}
try {
  $win = $null
  for ($i = 0; $i -lt 60 -and -not $win; $i++) {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $app.Id)
    $win = $A::RootElement.FindFirst($T::Children, $c)
    if (-not $win) { Start-Sleep -Milliseconds 250 }
  }
  Check ($win -ne $null) "the window, found by UI Automation"
  if ($win) {
    $btn = Named $win "Press me"
    Check ($btn -and $btn.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) "the button: a Button named Press me"
    $chk = Named $win "Keep it"
    Check ($chk -and $chk.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox) "the check box"
    $edits = $win.FindAll($T::Descendants, (New-Object System.Windows.Automation.PropertyCondition(
      $A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
    Check ($edits.Count -ge 1) "a text box ($($edits.Count))"
    if ($btn) {
      $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
      for ($i = 0; $i -lt 40 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 250 }
      Check ((Test-Path $out) -and ((Get-Content $out) -like "pressed*")) "the button pressed through UI Automation"
    }
  }
} finally {
  if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
if ($failed -gt 0) { Write-Host "$failed failed"; exit 1 }
Write-Host "screen readers on Windows: ok"
