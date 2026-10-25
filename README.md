# qMail

A simple, native macOS mail client built with SwiftUI and Liquid Glass. It works with Gmail, Outlook, iCloud, Yahoo, Fastmail, AOL and any IMAP/SMTP server. Its signature feature is **Chats**: every email between the same group of people, across all subjects, becomes one conversation you can read and reply to like a messaging app.

## Features

- **Chats.** Email is threaded (References / In-Reply-To / Gmail thread IDs), then threads with exactly the same people are merged into one chat. Quoted replies, "On … wrote:" headers (English, Czech, German, French, Spanish and more), signatures and "Sent from my iPhone" footers are stripped, so each message reads like a chat bubble. Topic changes show as dividers, and the reply box lets you continue any topic or start a new one. Newsletters and notifications stay out of Chats. You can pin, rename or hide chats, and filter by Groups, People or Unread.
- **Classic mail.** Unified inbox, folders (including localized and nested names), message list with unread/flag/attachment state, swipe actions, reader with attachments, reply / reply all / forward, move, archive and delete.
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
| Gmail | Sign in with Google (needs an OAuth client ID, see below) **or** an [app password](https://myaccount.google.com/apppasswords) (requires 2-Step Verification). |
| Outlook / Hotmail / Microsoft 365 | Sign in with Microsoft only. Outlook's IMAP server no longer accepts passwords (`LOGINDISABLED`, `AUTH=XOAUTH2` only). |
| iCloud | An app-specific password from [account.apple.com](https://account.apple.com) → Sign-In and Security. |
| Yahoo / AOL / Fastmail | An app password from your account security settings. |
| Other | Email and password. Server settings are looked up automatically in Mozilla's ISP database, or you can enter them yourself. |

## Setting up "Sign in with Google / Microsoft"

OAuth needs a client ID that you register yourself. It's free and takes a few minutes. Enter the IDs in **qMail ▸ Settings ▸ Sign-In**, or bake them into the build in `qMail/Store/AppSettings.swift` (`OAuthDefaults`).

### Google (Gmail)

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Gmail API**.
2. Configure the **OAuth consent screen** (External). Add the scope `https://mail.google.com/` and add yourself as a test user.
3. Under **Credentials ▸ Create credentials ▸ OAuth client ID**, choose **iOS** and enter the bundle ID `com.honzakubita.qmail`.
4. Copy the client ID into Settings ▸ Sign-In. The redirect URI (`com.googleusercontent.apps.<id>:/oauth2redirect`) is derived automatically.

### Microsoft (Outlook, Hotmail, Microsoft 365)

1. In [Microsoft Entra ▸ App registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade), create a registration for **Accounts in any organizational directory and personal Microsoft accounts**.
2. Under **Authentication ▸ Add a platform ▸ Mobile and desktop applications**, add the redirect URI `msauth.com.honzakubita.qmail://auth`.
3. Under **API permissions**, add the delegated permissions `IMAP.AccessAsUser.All`, `SMTP.Send`, `offline_access`, `openid`, `email` and `profile` (Office 365 Exchange Online / Microsoft Graph).
4. Copy the **Application (client) ID** into Settings ▸ Sign-In.

## How Chats are built

1. Messages from Inbox, Sent and Archive/All Mail are deduplicated by Message-ID.
2. They're grouped into threads with union-find over `Message-ID`, `In-Reply-To`, `References` and Gmail's `X-GM-THRID`. Replies to a parent you don't have still end up together.
3. Each thread's participants are everyone in From/To/Cc except you. Your aliases are learned from what you send.
4. Threads with the same participant set become one chat. Threads made only of automated mail (List-Id, List-Unsubscribe, Precedence: bulk, no-reply senders) are skipped unless you've replied in them. This can be changed in Settings.

Replying in a chat sends a proper reply-all email (`Re:` subject, `In-Reply-To` and `References`), so everyone else still sees a normal email thread.

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

To exercise the whole app without a real account, run the fake server and point a Debug build at it:

```bash
python3 Tools/fake_mail_server.py
QMAIL_TEST_SERVER=1 build/DerivedData/Build/Products/Debug/qMail.app/Contents/MacOS/qMail
QMAIL_FAKE_SERVER=1 swift test --package-path MailCore     # IMAP/SMTP integration tests
QMAIL_TEST_SERVER=remove build/DerivedData/Build/Products/Debug/qMail.app/Contents/MacOS/qMail   # remove the test account
```

## Limitations

- Each folder keeps the newest 250 messages locally by default (configurable). "Load Older Messages" and "Search on Server" reach the rest.
- Composing is plain text, with attachments. Drafts are not synced to the server.
- Sending needs a connection; there is no offline outbox yet.
