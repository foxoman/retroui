# Retro Mail: the Add Account wizard and signing in (again) in the browser.
# One click: "Microsoft" or "Google", the browser opens the service's own
# sign-in page, you sign in there, the account is here. (An organisation
# that allows only its own app registrations: "Advanced" takes its ID.)
# Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

var
  wizOpen = false
  wizStep = 0               ## 0 your address, 4 looking it up, 5 which service, 2 signing in,
                            ## 3 done, 1 an organisation's own app registration (from Options),
                            ## 6 an IMAP account's password and servers, 7 checking them
  wizKind = 0               ## 0 Microsoft (work, school or personal), 2 Google, 3 IMAP
  wizName, wizMail: string
  wizOwn = false            ## an app registration of your own, not the built-in one
  wizClient, wizSecret, wizTenant: string
  wizFlow: OAuthFlow
  wizError = ""
  wizAccount = 0            ## signing in again to this account (0: a new one)
  wizDoneText = ""

proc testBrowserThread(url: string) {.thread.} =
  ## (tests: the browser's part -- the sign-in page answers with a
  ## redirect to the loopback address, which is followed once)
  {.gcsafe.}:
    sleep(200)
    let r = httpRequest("GET", url, followRedirects = false, timeoutSec = 20)
    let loc = r.header("location")
    if loc.len > 0: discard httpRequest("GET", loc, timeoutSec = 20)

var testBrowserT: Thread[string]

# finding out where an address's mail is, off the window's thread
var detectT: Thread[string]
var detectCh: Channel[int]
var detectOpen = false

proc detectMain(email: string) {.thread.} =
  {.gcsafe.}: detectCh.send(detectService(email))

proc startDetect(email: string) =
  if not detectOpen:
    detectCh.open()
    detectOpen = true
  createThread(detectT, detectMain, email)

# ---- IMAP accounts: the servers found, the password checked, off the window's thread -----------

var
  wizPass = ""
  wizSrv: ImapServers
  wizSrvShown = false       ## the servers' fields are shown (found, or to set by hand)
  wizFound = ""             ## where they were found ("" a guess)
  findT: Thread[string]
  findCh: Channel[string]
  checkT: Thread[string]
  checkCh: Channel[string]
  imapChansOpen = false
  wizImapSec, wizSmtpSec: int   ## the combos' choices: 0 SSL/TLS, 1 STARTTLS, 2 None

const secNames = ["SSL/TLS", "STARTTLS", "None"]

proc secOf(i: int): Security =
  case i
  of 1: secStartTls
  of 2: secNone
  else: secTls

proc secIndex(s: Security): int =
  case s
  of secTls: 0
  of secStartTls: 1
  of secNone: 2

proc openImapChans() =
  if not imapChansOpen:
    findCh.open()
    checkCh.open()
    imapChansOpen = true

proc findMain(email: string) {.thread.} =
  {.gcsafe.}:
    let s = findMailServers(email)
    findCh.send($(%*{"imapHost": s.imap.host, "imapPort": s.imap.port, "imapSec": $s.imap.security,
                     "imapUser": s.imap.user, "smtpHost": s.smtp.host, "smtpPort": s.smtp.port,
                     "smtpSec": $s.smtp.security, "smtpUser": s.smtp.user, "found": s.found,
                     "source": s.source, "oauthOnly": s.oauthOnly}))

proc checkMain(job: string) {.thread.} =
  ## Signs in to both servers once: "" when both took the password.
  {.gcsafe.}:
    let j = parseJson(job)
    let acc = Account(email: j{"email"}.getStr, server: j{"server"}.getStr)
    checkCh.send(checkImapAccount(acc, j{"password"}.getStr))

proc startImapSetup() =
  ## The servers of the address, found while the password is typed.
  openImapChans()
  wizKind = 3
  wizError = ""
  wizStep = 6
  wizSrvShown = false
  wizFound = ""
  wizPass = ""
  ui.textFocusWanted = true
  if findT.running: joinThread(findT)          # (one search at a time)
  while findCh.tryRecv().dataAvailable: discard
  createThread(findT, findMain, wizMail.strip)

proc wizServers(): ImapServers =
  result = wizSrv
  result.imapSec = secOf(wizImapSec)
  result.smtpSec = secOf(wizSmtpSec)
  result.imapHost = result.imapHost.strip
  result.smtpHost = result.smtpHost.strip
  result.imapUser = result.imapUser.strip
  result.smtpUser = result.imapUser          # (one user name for both: the form has one)

proc startImapCheck() =
  wizError = ""
  wizStep = 7
  let job = %*{"email": wizMail.strip, "server": serverJson(wizServers()), "password": wizPass}
  if checkT.running: joinThread(checkT)
  createThread(checkT, checkMain, $job)

proc finishImap() =
  ## Both servers took the password: the account is kept.
  let s = wizServers()
  let email = wizMail.strip
  let id = if wizAccount > 0:
             store0.setAccountState(wizAccount, "")
             store0.setAccountServer(wizAccount, serverJson(s))
             wizAccount
           else: store0.addAccount(akImap, email, wizName.strip, "imap", "",
                                   prefInt("syncDays", 90), server = serverJson(s))
  discard saveSecret(secretApp, tokenKey(id), $(%*{"password": wizPass}))
  wizPass = ""
  link.cmds.send(SyncCmd(kind: scAccounts))
  wizDoneText = email
  wizStep = 3
  changed()

proc testBrowser(url: string) {.gcsafe.} =
  {.gcsafe.}: createThread(testBrowserT, testBrowserThread, url)

proc builtinId(kind: int): string =
  if kind == 2: googleAppId else: microsoftAppId

proc wizAccountObj(): Account =
  let own = wizOwn or builtinId(wizKind).len == 0
  Account(id: wizAccount, kind: (if wizKind == 2: akGmail else: akGraph),
          clientId: (if own: wizClient.strip else: builtinId(wizKind)),
          tenant: (if own and wizTenant.strip.len > 0: wizTenant.strip else: "common"))

proc wizSecretNow(): string =
  if wizKind != 2: ""
  elif wizOwn or googleAppId.len == 0: wizSecret.strip
  else: googleAppSecret

proc openWizard() =
  wizOpen = true
  ui.textFocusWanted = true
  wizStep = 0
  wizAccount = 0
  wizError = ""
  wizFlow = nil
  wizOwn = false
  wizMail = ""
  wizName = if accountsC.len > 0: accountsC[0].name else: ""
  wizClient = ""
  wizTenant = ""
  wizSecret = ""

proc startSignIn() =
  ## Opens the service's sign-in page in the browser, and waits for it.
  wizError = ""
  wizStep = 2
  let acc = wizAccountObj()
  let p = providerFor(acc, wizSecretNow())
  let browser: proc (url: string) {.gcsafe.} =
    if getEnv("RETRO_MAIL_TEST_BROWSER").len > 0: testBrowser else: nil
  wizFlow = beginSignIn(p, wizMail.strip, browser)

proc chooseService(kind: int) =
  wizKind = kind
  if builtinId(kind).len == 0 and not wizOwn:
    wizError = "This copy of Retro Mail was built without its " &
               (if kind == 2: "Google" else: "Microsoft") & " app registration, so it " &
               "cannot open the sign-in page yet (docs/retromail.md: for whoever builds it)."
    wizStep = 5
  else:
    startSignIn()

proc ownRegistration*() =
  ## (Options > Accounts: an organisation that allows only its own apps)
  openWizard()
  wizOwn = true
  wizKind = 0
  wizClient = pref("msClient")
  wizTenant = pref("msTenant")
  wizStep = 1

proc signInAgain(acc: Account) =
  openWizard()
  wizAccount = acc.id
  if acc.kind == akImap:
    # (the password, typed again; the servers, to change)
    openImapChans()
    wizKind = 3
    wizMail = acc.email
    wizName = acc.name
    wizSrv = serversOf(acc)
    wizImapSec = secIndex(wizSrv.imapSec)
    wizSmtpSec = secIndex(wizSrv.smtpSec)
    wizSrvShown = true
    wizFound = "kept"
    wizPass = ""
    wizStep = 6
    ui.textFocusWanted = true
    return
  wizKind = if acc.kind == akGmail: 2 else: 0
  wizMail = acc.email
  wizName = acc.name
  wizOwn = acc.clientId != builtinId(wizKind) or builtinId(wizKind).len == 0
  wizClient = acc.clientId
  wizTenant = if acc.tenant in ["organizations", "consumers", "common"]: "" else: acc.tenant
  if acc.kind == akGmail: wizSecret = loadSecret(secretApp, secretKey(acc.id))
  startSignIn()

proc finishSignIn() =
  ## The browser said yes: who is it, then the account is kept.
  let t = wizFlow.tokens
  let acc = wizAccountObj()
  var email = wizMail.strip
  var name = wizName.strip
  try:
    case acc.kind
    of akGraph:
      let me = graphMe(t.accessToken)
      if me.email.len > 0: email = me.email
      if name.len == 0: name = me.name
    of akGmail:
      let p = gmailProfile(t.accessToken)
      if p.email.len > 0: email = p.email
      if name.len == 0: name = claims(t){"name"}.getStr
    of akImap: discard
  except CatchableError as e:
    let c = claims(t)
    if email.len == 0: email = c{"email"}.getStr(c{"preferred_username"}.getStr)
    if email.len == 0:
      wizError = "Signed in, but your address could not be read: " & e.msg
      return
  let id = if wizAccount > 0:
             store0.setAccountState(wizAccount, "")
             wizAccount
           else: store0.addAccount(acc.kind, email, name, acc.clientId, acc.tenant,
                                   prefInt("syncDays", 90))
  discard saveSecret(secretApp, tokenKey(id), $(%t))
  if acc.kind == akGmail: discard saveSecret(secretApp, secretKey(id), wizSecretNow())
  if wizOwn:
    # (your own registration: kept for the next account)
    if acc.kind == akGmail:
      prefs.put("gClient", acc.clientId)
      discard saveSecret(secretApp, "google-client-secret", wizSecretNow())
    else:
      prefs.put("msClient", acc.clientId)
      prefs.put("msTenant", wizTenant.strip)
    savePrefs()
  link.cmds.send(SyncCmd(kind: scAccounts))
  if not prefBool("sigWeb" & $id, false):
    link.cmds.send(SyncCmd(kind: scSignatures, id: id))   # (its signature from the web)
  wizDoneText = email
  wizStep = 3
  changed()

proc wizardArt(w, h: int) =
  let r = place(w, h)
  for i in 0 ..< h:
    hline(r.x, r.y + i, r.w, rgb(0, 60 + i * 60 div max(h, 1), 120 + i * 80 div max(h, 1)))
  let globe = pixelIcon(pxGlobe, big = true)
  image(r.x + (w - 2 * globe.w) div 2, r.y + dp(40), globe, 2)
  let m = pixelIcon(pxMail, big = true)
  image(r.x + (w - 3 * m.w) div 2, r.y + dp(140), m, 3)
  sunken(r)

proc serviceButton(px, title, detail: string): bool =
  ## A big button that names a service (Microsoft, Google).
  let lh = lineHeight()
  let r = place(available(), 2 * lh + dp(22), fill = true)
  let hit = interact(idOf("svc" & title), r)
  fill(r, if hit.hover: rgb(232, 232, 244) else: ui.theme.face)
  if hit.down: sunken(r) else: raised(r, 2)
  box(r, ui.theme.frame)
  let ic = pixelIcon(px, big = true)
  image(r.x + dp(10), r.y + (r.h - ic.h) div 2, ic)
  text(r.x + dp(54), r.y + dp(8), title, ui.theme.text, style(bold = true))
  text(r.x + dp(54), r.y + dp(10) + lh, detail, ui.theme.gray)
  if hit.focused: focusDots(inset(r, 4))
  hit.clicked

proc lookUp() =
  ## Next on the address: find its service, then sign in.
  let e = wizMail.strip
  if '@' notin e or '.' notin e.split('@')[^1]:
    wizError = "That does not look like an e-mail address."
    return
  wizError = ""
  wizStep = 4
  startDetect(e)

proc wizardDialog() =
  if wizStep == 4 and detectOpen:
    let (ok, kind) = detectCh.tryRecv()
    if ok:
      joinThread(detectT)
      if kind < 0: wizStep = 5
      else: chooseService(kind)
    else: wakeIn(200)
  if wizStep == 6 and imapChansOpen and not wizSrvShown:
    let (ok, js) = findCh.tryRecv()
    if ok:
      joinThread(findT)
      let j = try: parseJson(js) except CatchableError: newJObject()
      wizSrv = ImapServers(imapHost: j{"imapHost"}.getStr, imapPort: j{"imapPort"}.getInt(993),
                           imapSec: parseSecurity(j{"imapSec"}.getStr("tls")),
                           imapUser: j{"imapUser"}.getStr(wizMail.strip),
                           smtpHost: j{"smtpHost"}.getStr, smtpPort: j{"smtpPort"}.getInt(465),
                           smtpSec: parseSecurity(j{"smtpSec"}.getStr("tls")),
                           smtpUser: j{"smtpUser"}.getStr(wizMail.strip))
      wizImapSec = secIndex(wizSrv.imapSec)
      wizSmtpSec = secIndex(wizSrv.smtpSec)
      wizFound = if j{"found"}.getBool: j{"source"}.getStr else: ""
      wizSrvShown = true
      if j{"oauthOnly"}.getBool:
        wizError = "This provider takes no password here: it wants its own sign-in."
    else: wakeIn(200)
  if wizStep == 7 and imapChansOpen:
    let (ok, err) = checkCh.tryRecv()
    if ok:
      joinThread(checkT)
      if err.len == 0: finishImap()
      else:
        wizError = err
        wizStep = 6
    else: wakeIn(200)
  if wizFlow != nil and wizStep == 2:
    case wizFlow.state
    of osDone:
      finishSignIn()
      wizFlow = nil
    of osFailed:
      wizError = wizFlow.error
      wizFlow = nil
    of osCancelled: wizFlow = nil
    of osWaiting: wakeIn(300)
  let compact = isCompact()
  let width = if compact: ui.w - dp(16) else: dp(640)
  dialog wizOpen, (if wizAccount > 0: "Sign In Again" else: "Add Account Wizard"), width:
    row([(if compact: 0 else: dp(150)), -1]):
      if not compact: wizardArt(dp(150), dp(330))
      col:
        case wizStep
        of 0:
          label "Add an E-mail Account", bold = true
          paragraph "Type your e-mail address. Retro Mail finds where your mail is. " &
                    "Microsoft 365, Outlook.com and Gmail open their own sign-in page in " &
                    "your browser (Retro Mail never sees that password); any other " &
                    "provider takes your password here."
          space()
          form dp(110):
            field "&E-mail address:": edit wizMail
          label "Microsoft 365, Outlook.com, Hotmail, Gmail, Google Workspace -- or any " &
                "other provider, with IMAP.", color = ui.theme.gray
          if wizError.len > 0:
            space()
            label wizError, color = rgb(200, 0, 0)
        of 4:
          label "Add an E-mail Account", bold = true
          space()
          row:
            spinner()
            label "Finding where the mail of " & wizMail.strip & " is...", bold = true
        of 5:
          label "Where Is Your Mail?", bold = true
          if wizError.len > 0:
            paragraph wizError
          else:
            paragraph "Retro Mail could not tell from " & wizMail.strip & ". Choose its service:"
          space()
          if serviceButton(pxGlobe, "Microsoft 365 or Outlook.com",
                           "Work, school, Outlook.com, Hotmail, Live"):
            wizError = ""
            chooseService(0)
          space()
          if serviceButton(pxMail, "Gmail or Google Workspace", "Your Google account"):
            wizError = ""
            chooseService(2)
          space()
          if serviceButton(pxComputer, "Another provider (IMAP)",
                           "Any mail server, with your password"):
            startImapSetup()
        of 6:
          label (if wizAccount > 0: "Your Password Again" else: "Your Mail Server"), bold = true
          if wizAccount == 0:
            paragraph "Retro Mail reads your mail with IMAP and sends it with SMTP, signed in " &
                      "with your password (kept encrypted on this computer). Gmail, Yahoo, " &
                      "iCloud and others want an app password here: make one in your " &
                      "account's security settings."
          else:
            paragraph "The server did not take the password kept for " & wizMail.strip &
                      " (changed?). Type it again; the servers can be changed below."
          form dp(110):
            if wizAccount == 0: field "Your &name:": edit wizName
            field "&Password:": edit(wizPass, password = true)
          if not wizSrvShown:
            row:
              spinner()
              label "Finding the servers of " & wizMail.strip.split('@')[^1] & "...", bold = true
          else:
            label (if wizFound == "kept": "The servers:"
                   elif wizFound.len > 0: "Found (" & wizFound & "):"
                   else: "Not found: these are a guess, check them:"),
                  color = ui.theme.gray
            form dp(110):
              field "&Incoming (IMAP):":
                row([-1, dp(64), dp(96)]):
                  edit wizSrv.imapHost
                  intEdit(wizSrv.imapPort, lo = 1, hi = 65535)
                  if combo(secNames, wizImapSec):
                    wizSrv.imapPort = defaultPort(true, secOf(wizImapSec))
              field "&Outgoing (SMTP):":
                row([-1, dp(64), dp(96)]):
                  edit wizSrv.smtpHost
                  intEdit(wizSrv.smtpPort, lo = 1, hi = 65535)
                  if combo(secNames, wizSmtpSec):
                    wizSrv.smtpPort = defaultPort(false, secOf(wizSmtpSec))
              field "&User name:": edit wizSrv.imapUser
            checkbox("&Take the server's own certificate (a server of yours, at home)",
                     wizSrv.insecure)
          if wizError.len > 0:
            space()
            label wizError, color = rgb(200, 0, 0)
        of 7:
          label "Signing In", bold = true
          space()
          row:
            spinner()
            label "Signing in to " & wizSrv.imapHost.strip & " and " & wizSrv.smtpHost.strip & "...",
                  bold = true
        of 1:
          label (if wizKind == 2: "Your Google App" else: "Your Organisation's App"), bold = true
          if wizKind == 2:
            paragraph "In console.cloud.google.com: enable the Gmail and Google Calendar " &
                      "APIs, then Credentials, OAuth client ID, \"Desktop app\"."
            form dp(110):
              field "&Client ID:": edit wizClient
              field "Client &secret:": edit(wizSecret, password = true)
          else:
            paragraph "For an organisation that allows only its own apps: the Application " &
                      "ID of its registration (entra.microsoft.com, App registrations: " &
                      "\"Mobile and desktop\" with http://localhost, public client flows on, " &
                      "Mail.ReadWrite, Mail.Send, Calendars.Read)."
            row:
              radio("&Microsoft", wizKind, 0)
              radio("&Google", wizKind, 2)
            form dp(110):
              field "&Application ID:": edit wizClient
              if wizKind == 0:
                field "&Tenant ID:": edit wizTenant
          label "Kept for your next account.", color = ui.theme.gray
        of 2:
          label "Sign In", bold = true
          if wizFlow != nil:
            row:
              spinner()
              label "Waiting for " & (if wizKind == 2: "Google" else: "Microsoft") & "...", bold = true
            paragraph "Your browser opened the sign-in page. Sign in there and allow Retro " &
                      "Mail to read and send your mail; this window goes on by itself."
            row:
              if link("Open it again"): discard openUrl(wizFlow.url)
              if link("Copy the address"): putClipboardText(wizFlow.url)
            if button("Cancel"):
              wizFlow.cancel()
              wizFlow = nil
              wizStep = 0
          if wizError.len > 0:
            label "It did not work:", bold = true, color = rgb(200, 0, 0)
            paragraph wizError
            if button("Try Again", pxRefresh, isDefault = true): startSignIn()
        else:
          label "Congratulations", bold = true
          paragraph "You are signed in as " & wizDoneText & ". Retro Mail is downloading " &
                    "your mail now: the newest first, so you can start reading at once."
    separator()
    row:
      space available() - 3 * (dp(84) + Gap) + Gap
      if button("< &Back", enabled = wizStep in {1, 2, 5, 6} and wizFlow == nil and wizAccount == 0,
                w = dp(84)):
        wizStep = 0
        wizError = ""
      if wizStep == 0:
        if button("&Next >", isDefault = true, enabled = wizMail.strip.len > 3, w = dp(84)): lookUp()
      elif wizStep == 1:
        let ok = if wizKind == 2: wizClient.strip.len > 10 and wizSecret.strip.len > 4
                 else: wizClient.strip.len > 10
        if button("&Sign In", isDefault = true, enabled = ok, w = dp(84)): startSignIn()
      elif wizStep == 6:
        if button("&Next >", isDefault = true, w = dp(84),
                  enabled = wizSrvShown and wizPass.len > 0 and wizSrv.imapHost.strip.len > 0 and
                            wizSrv.smtpHost.strip.len > 0): startImapCheck()
      elif wizStep == 3:
        if button("&Finish", isDefault = true, w = dp(84)):
          wizOpen = false
          view = vMail
          place = Place(kind: plAllInbox)
          treeSel = "fav:inbox"
          changed()
      else:
        button("&Next >", enabled = false, w = dp(84))
      if button((if wizStep == 3: "Close" else: "Cancel"), w = dp(84)):
        if wizFlow != nil: wizFlow.cancel()
        wizFlow = nil
        wizOpen = false
