# Retro Mail

Outlook Express 4 to look at and to use, with what the new Outlook does:
Microsoft 365 (work or school), Outlook.com, Gmail -- and any other
provider's mail, through IMAP, POP3, JMAP or a company's own Exchange --
side by side.

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
- **Kept encrypted.** That file, and its journal, are encrypted page by
  page (XChaCha20-Poly1305), with a key made the first time and kept in the
  system's keyring: whoever has the disk, or a copy of it, reads nothing
  (below: *Safety*).
- **New mail at once.** An IMAP server that can (IDLE) says the moment mail
  comes, is read elsewhere or goes; Retro Mail fetches it then, not at the
  next check.
- **Who it is from, checked.** The provider's own checks (DMARC, DKIM,
  SPF), believed only from its own servers, and the message's DKIM
  signature verified here; a sender's name that is a company's they are
  not, a look-alike domain, a link that goes elsewhere than it says,
  tracking pictures and codes: told, or taken out.
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

### Any other provider: IMAP, POP3, JMAP, Exchange

An address Retro Mail does not know, or *Another provider (IMAP, POP3,
JMAP, Exchange)* on the wizard's "Where Is Your Mail?" page: choose how
its mail is read (*Read with:* IMAP, POP3, JMAP or Exchange), type your
name and your password,
and the servers are found meanwhile -- the biggest providers by name,
then the provider's own autoconfig file, Thunderbird's list of providers,
the domain's DNS (its SRV records; its MX host's provider), and last the
usual names (imap.example.com, smtp.example.com), marked as a guess.
Check them (the incoming IMAP server, the outgoing SMTP server, their
ports and encryption -- SSL/TLS or STARTTLS -- and the user name),
change what is wrong, and *Next* signs in to both; the mail comes.

- Many providers want an **app password** here, not the account's own:
  Gmail (with 2-step verification), Yahoo, iCloud, AOL, Fastmail, Zoho,
  Yandex, Mail.ru, Proton (its Bridge's). The wizard says where to make
  one for the provider it found (Gmail and Outlook.com are added better
  through their own sign-in, above).
- **New mail at once:** an IMAP account whose server can (IDLE: most can)
  is watched on a connection of its own; the server tells, Retro Mail
  fetches. (On Android and iOS the system's own background checks do it.)
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

**POP3** reads a provider's Inbox (POP3 has nothing else): each message
downloaded whole, once, and left on the server unless *Leave a copy of each
message on the server* is cleared; the other folders -- Sent, Drafts,
Trash, Junk -- are kept here, and a message deleted from the Trash here is
deleted on the server too. Sending is through SMTP, a copy kept in Sent.
The big providers' POP3 servers are known (Gmail, Outlook.com, Yahoo, AOL,
Fastmail, GMX, WEB.DE, Zoho, Yandex, mailbox.org, Posteo).

**JMAP** (Fastmail, Stalwart, Cyrus): the JMAP server's address (Fastmail's
is found by itself; another domain's from its DNS), and an API token as the
password -- or a user name and a password. The mailboxes, then only what
changed since the last time; read, flags, tags (as keywords), moves,
deletes, sending (kept in Sent), the server's search.

**Exchange** (a company's own, 2010 and later, through Exchange Web
Services): its EWS address (`https://mail.example.com/EWS/Exchange.asmx`)
and your user name (`DOMAIN\name`, or your address); Retro Mail signs in
as Windows does (NTLM) where the server will not take the password plainly.
The folders, what changed in each since the last time, read, flags,
categories (as tags), moves, deletes, sending (kept in Sent Items), the
server's search. (Microsoft 365 is added better through its own sign-in,
above.)

## Safety

**Who a message is from.** As its body comes, Retro Mail checks its
sender -- the domain of its From address:

- the results the account's provider wrote when it took the message in
  (Authentication-Results: DMARC, DKIM, SPF), believed only from the
  provider's own servers (Gmail's mx.google.com, Microsoft's, iCloud's,
  Yahoo's, Fastmail's, Zoho's -- or, for another provider, the server that
  wrote the topmost of them on at least 50 of its messages and 80 in a
  hundred) and only the topmost one: anyone can write one into a message
  they send;
- else its DKIM signature, verified here (RSA and Ed25519) against the key
  its domain publishes in DNS, asked of the system's own resolver: a
  signature of the From address's own domain (or its organization's,
  `mail.example.com` for `example.com`) proves who sent it; one of another
  domain proves nothing;
- else the domain's DMARC policy: a domain that asks for its mail to be
  proven (quarantine, reject), on a message nothing proves, is said to be
  unproven.

A message that is not from who it says is marked in red over the message,
with *Block Sender* and *Move to Junk*; one that could not be confirmed, in
yellow; one checked says so quietly, in gray ("From example.com, checked").

**What is there to fool.** Over the message: a sender whose name says a
company (PayPal, Microsoft, Apple, a bank, a courier) while the mail comes
from another domain; an address in the name that is not the sender's; a
domain that looks like a well-known one or like one of the people you write
to (`paypa1.com`, `rnicrosoft.com`, letters of another alphabet); links
whose words name one site and go to another, or that hide where they go (a
name before an `@`, a bare IP address). Clicking such a link asks first; a
link that runs a script is not opened.

**Tracking.** Pictures from the web are hidden until you show them (for the
message, the sender, or always), so a sender cannot see when you read it;
the pictures that are there only for that -- a pixel or two, hidden, a
tracking service's -- are taken out even then, and tracking codes
(`utm_source`, `fbclid`, `gclid`, `mc_eid`...) come off the links you open.
The pane says what it took out.

**The mail kept here** is encrypted (Tools > Options > Security: *Keep the
mail on this device encrypted*, on from the start; the mail of an older
version is encrypted the first time this one starts, and decrypted again
when the box is cleared). The key is made the first time and kept in the
system's keyring (DPAPI, the keychain, libsecret, the app's private
folder): without it the file is noise, and a byte changed on disk is found
when it is read. Should the key be lost (the keyring wiped), the file is
set aside and the accounts are added again: their mail comes down again
from the servers. The keyring is asked as the window opens, not before:
one that asks for its password first (a keychain locked) shows *Opening
the mail kept on this device...* until it is answered.

Tools > Options > Security turns the warnings and the taking out of
tracking off (and on again).

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
`after:` and plain words; *Search the server* goes beyond what is kept --
and asks each server the same thing its own way (IMAP's SEARCH, Gmail's
search, Microsoft's KQL, JMAP's filter, Exchange's AQS), so it finds what
the same search finds here.

On a phone or a tablet in Glass, Matte or Gloss (a phone starts in Gloss;
Tools > Options > Appearance changes it) Retro Mail is a phone's mail as 2012
drew it: Mailboxes -- All Inboxes and each account's inbox with its unread,
Flagged, Unread, your accounts, Add Account, Calendar, People, To Do, Notes,
Settings --, a folder's messages on white with a blue dot on the unread ones
(Edit, or a finger held on one, chooses several: Mark, Move, Trash), one
message with "3 of 9" and its arrows, its toolbar (Flag or Mark, Move, Trash,
Reply, New Message), writing with Cancel and Send. Settings is a phone's, in
groups: your accounts and Add Account; New Mail (how often it is checked, how
long it is kept to read offline, while Retro Mail is closed, Tell Me, Sound);
Reading (threads, Focused Inbox, when a message is marked read, pictures from
the web, plain text); Writing (replies in blue, Undo Send); Kept Safe (the
mail kept encrypted, look-alikes, trackers); Appearance; and More Options for
the rest (signatures, spelling, swipes, tags, the assistant) -- each kept as
it is changed. On a tablet the mailboxes and the list stay down the left, the
message beside them.

On a phone in the 3.1 look each screen comes alone (folders, list,
conversation, writing) and the Outlook bar sits at the bottom; swipe a message right to archive
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
  Translate a message with the Assistant's service below (1.4) -- this
  device's own model sends nothing anywhere -- or, with none set, with your
  own key (Claude, by Anthropic). Nothing is sent before you turn it on,
  and then only what you ask about.
- **The Assistant pane** (View > Assistant, 1.3): a conversation with an AI
  service of your own -- one on your computer (Ollama, LM Studio), OpenAI's,
  Anthropic's -- set in Tools > Options > Assistant. Ask it what came from
  someone, to sum up a thread, to answer a message: it lists, finds and
  reads messages (without what they quote) and opens a reply or a new
  message for you to read and send -- it never sends; it marks messages read
  or flagged when you allow it. It sends the service only what it reads to
  answer you. Until a service is set, the key of the Summarize above is
  used with Anthropic's. Since 1.4 the service can be **this device's own
  model** (Models: BitNet b1.58 2B, Qwen3 1.7B), which sends nothing
  anywhere; with Qwen3 Embedding on the device it also **finds mail by
  meaning** -- "the invoice from Ahmed" finds a bill from Ahmad (the
  newest 400 messages, read once each).
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
