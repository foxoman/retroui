# Retro Mail

Outlook Express 4 to look at and to use, with what the new Outlook does:
Microsoft 365 (work or school), Outlook.com, Gmail -- and any other
provider's mail, through IMAP and SMTP -- side by side.

- **Signed in in the browser.** The service's own sign-in page opens in
  your browser (OAuth 2.0 with PKCE, answered on a loopback address).
  Retro Mail never sees a password; it keeps an encrypted sign-in token
  (DPAPI on Windows, the keychain on macOS, libsecret or an encrypted file
  on Linux, the app's private folder on Android).
- **Official APIs for Microsoft and Google:** Microsoft Graph and the
  Gmail API (and Google Calendar), one click to add an account, no
  password (below). **Every other provider through IMAP and SMTP**, with
  its password (or an app password), the servers found by themselves;
  the password is kept encrypted as the tokens are.
- **Offline first.** Mail is kept in a local SQLite file with a full-text
  index: the list opens at once, search answers in milliseconds without the
  network, and changes made offline go out when the network comes back.
- **What the new Outlook does:** threads, Focused and Other, tags (Outlook
  categories, Gmail labels, with their colors), flags, pin, snooze,
  quick replies, the calendar, people, to do, notes, signatures for new
  mail and for replies, send later, attachments of any size.
- **Replies in blue,** as Outlook wrote them (Tools > Options > General
  turns it off).
- **Your own signature.** The one Gmail keeps in its settings, and the one
  Outlook (on the web, the new Outlook, Outlook for Windows) put under the
  mail you sent last, for new messages and for replies, come by themselves
  when an account is added (Tools > Options > Signatures > *From the Web*
  reads them again).
- **What Outlook Express did:** the start page, the Outlook bar, the folder
  tree with unread counts, the contacts pane, threads with + and - boxes,
  the preview pane with its gray header, "----- Original Message -----",
  the Internet Connection Wizard (as the Add Account Wizard), Tools >
  Options with its tabs.
- **No browser inside.** Mail is drawn by the toolkit's own HTML view
  (tables, styles, hidden preheaders, inline pictures, right to left);
  pictures from the web wait until you ask, so senders cannot see when you
  read their mail.

## Adding an account

File > Add Account (it opens by itself the first time): type your e-mail
address and press Enter. Retro Mail finds where your mail is (Outlook.com,
Hotmail and Gmail by name; a company's domain by its Microsoft 365 tenant or
its mail servers), and your browser opens that service's own sign-in page,
with your address filled in. Sign in, allow Retro Mail, and the window goes
on by itself. That is all.

(An organisation that allows only apps it registered itself: Tools >
Options > Accounts > *Organisation's App* takes its Application ID.)

### Any other provider: IMAP

An address Retro Mail does not know, or *Another provider (IMAP)* on the
wizard's "Where Is Your Mail?" page: type your name and your password,
and the servers are found meanwhile -- the biggest providers by name,
then the provider's own autoconfig file, Thunderbird's list of providers,
the domain's DNS (its SRV records; its MX host's provider), and last the
usual names (imap.example.com, smtp.example.com), marked as a guess.
Check them (the incoming IMAP server, the outgoing SMTP server, their
ports and encryption -- SSL/TLS or STARTTLS -- and the user name),
change what is wrong, and *Next* signs in to both; the mail comes.

- Many providers want an **app password** here, not the account's own:
  Gmail (with 2-step verification), Yahoo, iCloud, AOL, Outlook.com.
  Make one in the account's security settings (Gmail and Outlook.com are
  added better through their own sign-in, above).
- A server of your own with a certificate it signed itself: *Take the
  server's own certificate* (the mail is still encrypted).
- What it does: the folders with what they are for (Sent, Drafts, Trash,
  Junk, Archive), the mail of the days kept (Tools > Options), then only
  what is new and only the flags that changed; read, flags, tags (as IMAP
  keywords, Thunderbird's own five as theirs), moves, deletes, all made on
  the server; sending through SMTP, a copy in Sent (Gmail and Microsoft
  365 keep one themselves); meeting invitations read from the message and
  answered by mail; search of the server's Inbox and Sent as well.
- What it does not: an IMAP account has no calendar and no automatic
  replies here (IMAP has neither; the provider's web mail sets them).
- When the server stops taking the password (it was changed), the
  account says so and asks for it again. Tools > Options > Accounts >
  *Servers...* changes the servers.

## For whoever builds it: the app registrations, once

A program signs in to Microsoft and Google as a registered app. Make the two
registrations once, as the developer, and build them in: every user then
signs in with one click. A client ID names the app, not anyone's account,
and is public (every desktop mail program carries one); Google says a
desktop client's "secret" is not kept secret either.

**Microsoft** (<https://entra.microsoft.com>, App registrations > New registration):

1. Name "Retro Mail"; supported accounts: *any organisational directory and
   personal Microsoft accounts*.
2. Authentication > Add a platform > *Mobile and desktop applications*:
   `http://localhost`. *Allow public client flows*: Yes.
3. API permissions > Microsoft Graph > Delegated: `Mail.ReadWrite`,
   `Mail.Send`, `Calendars.ReadWrite` (events, answering invitations),
   `MailboxSettings.ReadWrite` (automatic replies), `User.Read`,
   `offline_access`.
4. Branding: verify the publisher (an organisation's users can then allow
   it themselves where their admins let them; some companies still have an
   administrator approve new apps once).

**Google** (<https://console.cloud.google.com>):

1. A project; enable the *Gmail API* and the *Google Calendar API*.
2. OAuth consent screen: External; scopes (Data Access) `gmail.modify`,
   `gmail.settings.basic` (the vacation reply and the signature) and
   `calendar.events` (the calendar's events, made and changed here). Until
   Google verifies the app, only the test users
   you list (up to 100) can sign in, and they see an "unverified app"
   page; Gmail's scopes need Google's verification (and its yearly security
   review) before anyone at all can.
3. Credentials > Create credentials > OAuth client ID > *Desktop app*.

Then put the three values in `examples/mail/appids.nim`, or give them when
building (GitHub Actions takes them from repository secrets of the same
names):

```sh
RETRO_MAIL_MICROSOFT_ID=... RETRO_MAIL_GOOGLE_ID=... RETRO_MAIL_GOOGLE_SECRET=... nimble mailapk
```

A build without them asks each user for an app registration of their own.

## Using it

| Keys | |
|---|---|
| Ctrl+N | new message |
| Ctrl+R / Ctrl+Shift+R | reply / reply to all |
| Ctrl+F | forward |
| Ctrl+Enter, Alt+S | send (while writing) |
| Del / Backspace | delete / archive |
| Ctrl+Z | undo (a move, a message being sent) |
| Insert | flag |
| Ctrl+Q / Ctrl+U | mark read / unread |
| Ctrl+T | tags |
| Ctrl+Shift+V / Ctrl+Y | move to a folder / go to a folder |
| Ctrl+. / Ctrl+, | next / previous message |
| Enter | the message in a window of its own |
| Shift+arrows, Ctrl+click, Ctrl+A | select several |
| letters | jump to a sender |
| F6 | the next pane |
| Ctrl+E | search |
| Alt+Q | tell me what you want to do |
| F7 | spelling (while writing) |
| F5 | send and receive |
| Ctrl+1 ... Ctrl+5 | Mail, Calendar, People, To Do, Notes |

With the reading pane beside the list (View > Reading Pane), each message
takes three lines -- who and when, the subject and its marks, the tags and
the start of the text -- as Outlook shows it there. A message picked inside
an open thread opens in the conversation and comes to the top of the pane.
A message is read once it is opened (Tools > Options > General can wait a
few seconds, as Outlook Express did).

A click on an attachment opens it in the program the system has for it;
the right button (or a long press) also offers Save As and Save All, which
start in your Downloads folder.

Tags (Ctrl+T) open Outlook's Categorize menu: type to find a tag, or to make
a new one (an Outlook category, or a Gmail label).

The tool bar is yours: right-click it, or View > Customize Toolbar, to add,
remove and order its buttons and to choose how its labels show.

Search understands `from:`, `to:`, `subject:`, `has:attachment`, `tag:`,
`is:unread`, `is:flagged`, `is:pinned`, `in:sent`, `before:2026-01-01`,
`after:` and plain words; *Search the server* goes beyond what is kept.

On a phone each screen comes alone (folders, list, conversation, writing)
and the Outlook bar sits at the bottom; swipe a message right to archive
it, left to delete it (Tools > Options > Swipe changes what they do), hold
one to choose several, pull the list down to check for mail, swipe a
message you read sideways for the next one, pinch to make its text larger.

What 1.0.2 adds to the way you work:

- **Undo** for a delete, an archive or a move, and **Undo Send** (a message
  waits 10 seconds before it goes: Tools > Options > General).
- **Quick Steps** (Message > Quick Steps): several actions in one -- "Done"
  marks read and archives, make your own.
- **Sweep** (Message > Sweep): all the mail from one sender, now and from
  now on.
- **Follow Up** (Message > Follow Up): a flag with a day; Retro Mail reminds
  you when it comes.
- **Message Rules** (Tools): as Outlook Express had them, applied to mail as
  it comes -- tag it, move it, mark it read, flag it, delete it.
- **Meeting invitations** show what, when and where, with Accept,
  Tentative and Decline.
- **Automatic Replies** (Tools): out of office, for Microsoft 365, Outlook.com
  and Gmail.
- **Forward as Attachment**, **Save As** (.eml) and **Open a Saved Message**.
- **Local Folders**: File > Import brings your old mail in -- Outlook
  Express 4, 5 and 6 (found on the computer by itself), Thunderbird, Apple
  Mail, a Gmail Takeout (mbox) or .eml files. File > Export writes the list
  out as an mbox file.
- **Assistant** (Tools > Options > Assistant): Summarize a conversation and
  Translate a message with your own key (Claude, by Anthropic). Nothing is
  sent before you turn it on, and then only what you ask about.
- **Spelling** as you type and **AutoCorrect** in English and Arabic (Tools >
  Options > Spelling).

What 1.0.3 adds:

- **Print** (File > Print, Ctrl+P): the message laid out on paper as Outlook
  Express printed it -- From, Sent, To, Subject, a line, the text -- seen
  first, then printed or saved as a PDF.
- **Properties** (File > Properties, Alt+Enter) with the message's Internet
  headers, and **Message Source** (View, Ctrl+F3): the message as it
  travelled, to read or copy.
- **Unsubscribe** from a newsletter in one click (a bar over the message,
  when the list says how to leave it), and **Block Sender** (Message): their
  mail goes to Junk from now on.
- **Ignore Conversation** (Message): the conversation goes to Deleted Items,
  and so do its replies as they come.
- **Search Folders**: a search kept in the folder list (*Save as Search
  Folder* over the results), found again each time it is opened.
- **My Templates** (Insert, or the Templates button while writing): start a
  message from one, or keep the one being written as a template.
- **Find Message** (Edit, Ctrl+Shift+F): Outlook Express's dialog -- from,
  to, subject, words, received before or after, an attachment, flagged,
  unread, where to look.
- **Hide Read Messages** (View > Current View), as in Outlook Express;
  **Read all messages in plain text** (Tools > Options); pictures from the
  web: **Trust this sender**.
- **The sound of new mail** (Tools > Options > General): a chime, a ding,
  the old beep or a sound file of your own.
- **Drag out** an attachment, or messages (saved as .eml files), to a
  folder, the desktop or another program.
- **New mail on a phone while Retro Mail is closed:** Android checks every
  15 minutes or so (when there is a network; also after a restart) and
  tells it in a notification (Tools > Options > General turns it off).
- **Events and meetings** in the calendar, as the new Outlook makes them:
  New Event (or a double click on a time; on an event to change it; drag it
  to move it), with attendees -- invited by Microsoft 365 or Google
  themselves --, a Teams meeting or a Google Meet (*Join* in the event),
  repeat, reminder and notes; Delete sends the cancellation of a meeting
  you organize. Message > New Meeting invites the people of a message.

## Building

```sh
nimble mail                 # build and run
nimble mailexe              # Windows, from Linux (MinGW)
nimble mailapk              # Android
nim c -r tests/test_mail.nim   # the engine against tests/mailmock.py
nim c -r tests/test_calendar.nim   # events made, changed, deleted (the same stand-in)
```

Pin, snooze, follow-up days, rules, Quick Steps, notes, to-dos and drafts
are kept on the device. Events live in the accounts' own calendars (Gmail
accounts added before the calendar could be changed here sign in again
once: Tools > Accounts > Sign In Again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
