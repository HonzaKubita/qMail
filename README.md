# qMail

A simple, native macOS mail client built with SwiftUI and Liquid Glass. It works with Gmail, Outlook, iCloud, Yahoo, Fastmail, AOL and any IMAP/SMTP server. It's organized like Slack. Each account is a workspace, and every email lives in a chat. An email and its replies form a thread. Once someone replies to everyone on an email, the conversation becomes a group chat for exactly those people.

## Features

- **Workspaces.** Each account appears in a rail on the left, with an unread badge. Accounts never mix.
- **Chats.** The sidebar lists *Starred*, *Group chats*, *Direct messages* and *Updates* (newsletters and notifications). Mail you send only to yourself goes to your own "(you)" chat.
- **Threads.** In a chat, each email conversation is one message. Its replies collapse into "3 replies · Last reply 2 hours ago", which opens the thread in a panel on the right. Quoted text, "On … wrote:" headers (English, Czech, German, French, Spanish and more), signatures and mobile footers are stripped, so messages read cleanly.
- **Slack-style timeline.** Avatars, names, date dividers, a red "New" line at the first unread message, and a Liquid Glass hover toolbar (reply in thread, view email, flag, more).
- **Group chats need a group reply.** A one-off email to several people stays in the 1:1 chat with its sender, labelled "Sent to you, Bob & Carol". If you sent it, it appears in the chat with each recipient. A thread moves into a group chat only once someone replies to everyone.
- **No compose windows.** *New message* replaces the conversation view with a To: field. If you already have a chat with those people, its history shows below and your message joins it. Replying always happens in the bottom bar of the chat or thread. In a 1:1 chat, when the email also went to other people, the thread's bar offers **Reply to: Alice only / Everyone**; replying to everyone turns it into a group chat. Reply, Reply All and Forward from folders and from the full email open the same bottom bar or New Message view.
- **Composer.** Writing in a chat starts a new email thread to everyone in it. Unless you add a separate subject (**Aa**), the first line becomes the subject. That line is highlighted in the text, and a **SUBJECT** badge previews it. Writing in a thread sends a proper reply (`Re:`, `In-Reply-To`, `References`), so other people just see normal email. Return sends; Shift-Return adds a line.
- **Folders.** Inbox, Sent, Archive, Trash and your own folders are still available, collapsed at the bottom of the sidebar, with a classic message list and reader.
- **Push.** IMAP IDLE delivers new mail within seconds, with a periodic refresh as fallback.
- **Search.** Instant local search, plus "Search on Server" for older mail (uses Gmail's own search syntax on Gmail).
- **Private by default.** HTML mail is rendered with JavaScript disabled and remote images blocked until you choose to load them. Passwords and tokens are stored in the Keychain.
- **Native.** SwiftUI, Liquid Glass (glass toolbars, filter chips, composer, buttons), sandboxed, dark and light mode.
- **No dependencies.** IMAP, SMTP (with STARTTLS), MIME, OAuth 2 (PKCE) and threading are implemented in the local `MailCore` Swift package.

## Requirements

- macOS 26 or later (Liquid Glass)
- Xcode 26 or later

## Build and run

```bash
open qMail.xcodeproj
```

Press ⌘R. The project is set to automatic signing with team `5GYRSQQ6CW`; change it under *Signing & Capabilities* if needed.

From the command line:

```bash
xcodebuild -project qMail.xcodeproj -scheme qMail -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/qMail.app
```

## Adding accounts

| Provider | How to sign in |
| --- | --- |
| Gmail | **Sign in with Google** in a secure browser window. An [app password](https://myaccount.google.com/apppasswords) still works via "Use an App Password Instead". |
| Outlook / Hotmail / Microsoft 365 | **Sign in with Microsoft** only. Outlook's IMAP server no longer accepts passwords (`LOGINDISABLED`, `AUTH=XOAUTH2` only). |
| iCloud | An app-specific password from [account.apple.com](https://account.apple.com) → Sign-In and Security. |
| Yahoo / AOL / Fastmail | An app password from your account security settings. |
| Other | Email and password. Server settings are looked up automatically in Mozilla's ISP database, or you can enter them yourself. |

## OAuth clients (for developers)

"Sign in with Google" and "Sign in with Microsoft" use OAuth clients that are registered for qMail and built into the app in [`qMail/Store/OAuthClients.swift`](qMail/Store/OAuthClients.swift). Native apps are public clients, so these IDs are not secrets. If an ID is empty, that sign-in button is disabled.

If a Google sign-in expires (Google limits refresh tokens to 7 days while the app is in *Testing*) or is revoked, the account shows **Sign In Again…** in the sidebar.

### Google

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a project (for example "qMail").
2. **Google Auth Platform ▸ Branding**: set the app name, support email and developer contact.
3. **Audience**: choose *External*. While the app is in *Testing*, add every Google account that will sign in as a test user. *In production* (unverified) there is a user cap and a warning screen, but no 7-day sign-in expiry.
4. **Data access ▸ Add or remove scopes**: add `https://mail.google.com/`, `openid`, `email` and `profile`.
5. **Clients ▸ Create client**: application type **iOS**, bundle ID `com.honzakubita.qmail`. If the client shows *Advanced settings ▸ Enable custom URI scheme*, turn it on.
6. Put the client ID (`….apps.googleusercontent.com`) into `OAuthClients.googleClientID`. The redirect URI `com.googleusercontent.apps.<id>:/oauth2redirect` is derived from it, and no client secret is needed.

### Microsoft

1. In [Microsoft Entra ▸ App registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade), register an app for **Accounts in any organizational directory and personal Microsoft accounts**.
2. **Authentication ▸ Add a platform ▸ Mobile and desktop applications**: add `msauth.com.honzakubita.qmail://auth`.
3. **API permissions**: add the delegated permissions `IMAP.AccessAsUser.All` and `SMTP.Send` (Office 365 Exchange Online), plus `offline_access`, `openid`, `email` and `profile`.
4. Put the Application (client) ID into `OAuthClients.microsoftClientID`.

## How Chats are built

1. Messages from Inbox, Sent and Archive/All Mail are deduplicated by Message-ID.
2. They're grouped into threads with union-find over `Message-ID`, `In-Reply-To`, `References` and Gmail's `X-GM-THRID`. Replies to a parent you don't have still end up together.
3. Each thread's participants are everyone in From/To/Cc except you. Your aliases are learned from what you send.
4. A thread with at least one reply sent to two or more people (a "group reply") goes to the group chat for everyone involved. Otherwise each message goes to the 1:1 chat with its sender, or, for mail you sent, with each recipient. Chats are always per account. Inside a chat, each thread is one message placed where it started, and its replies open in the thread panel. Threads made only of automated mail (List-Id, List-Unsubscribe, Precedence: bulk, no-reply senders) are skipped unless you've replied in them. This can be changed in Settings.

Automated threads (List-Id, List-Unsubscribe, Precedence: bulk, no-reply senders) become chats under *Updates* unless you've written in them.

## Project layout

```
qMail/                  SwiftUI app
  App/                  App entry point, commands, debug hooks (Debug builds only)
  Store/                MailStore (sync, actions, chats), Keychain, cache, settings
  Views/                Sidebar, message list, reader, chats, compose, settings
MailCore/               Swift package with no app or UI code
  Transport/            URLSessionStreamTask connection (TLS and STARTTLS)
  IMAP/                 Response parser, client (IDLE, MOVE, UIDPLUS, Gmail extensions)
  SMTP/                 Submission client (PLAIN, LOGIN, XOAUTH2)
  MIME/                 Header/body parsing, encodings, HTML→text, message builder
  Auth/                 OAuth 2 + PKCE, ISP autodiscovery
  Chats/                ChatBuilder, QuoteStripper
  Tests/                Unit tests plus opt-in integration tests
Tools/fake_mail_server.py   Local IMAP/SMTP server with sample conversations
```

## Testing

```bash
cd MailCore && swift test              # unit tests
swift run MailProbe                    # TLS/STARTTLS + capabilities of every built-in provider (no login)
```

To exercise the whole app without touching your real accounts, build a separate dev copy (its own bundle ID, so its own sandbox container and Keychain items), run the fake server and point the dev copy at it:

```bash
xcodebuild -project qMail.xcodeproj -scheme qMail -configuration Debug -derivedDataPath build/DevDerivedData \
  PRODUCT_BUNDLE_IDENTIFIER=com.honzakubita.qmail.dev2 PRODUCT_NAME=qMailDev \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" DEVELOPMENT_TEAM=5GYRSQQ6CW build
python3 Tools/fake_mail_server.py
QMAIL_TEST_SERVER=2 QMAIL_SELECT=chat:0 build/DevDerivedData/Build/Products/Debug/qMailDev.app/Contents/MacOS/qMailDev
QMAIL_FAKE_SERVER=1 swift test --package-path MailCore     # IMAP/SMTP integration tests
QMAIL_TEST_SERVER=remove build/DevDerivedData/Build/Products/Debug/qMailDev.app/Contents/MacOS/qMailDev   # remove the test accounts
```

Sign the dev copy with your development certificate, as above. An ad-hoc signature changes with every build, which makes macOS ask for Keychain and app-data access each time. Other Debug-only hooks (`QMAIL_SELECT`, `QMAIL_SEND`, `QMAIL_REPLY`, `QMAIL_OPEN_THREAD`, `QMAIL_SNAPSHOT`) are documented in `qMail/App/DebugSupport.swift`.

## Limitations

- Each folder keeps the newest 250 messages locally by default (configurable). "Load Older Messages" and "Search on Server" reach the rest.
- Composing is plain text, with attachments. Drafts are not synced to the server.
- Sending needs a connection; there is no offline outbox yet.
