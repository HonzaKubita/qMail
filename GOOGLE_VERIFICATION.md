# Google OAuth verification for qMail

What Google needs before anyone outside the test-user list can add a Gmail account to qMail, and the text to paste into the forms.

- **Cloud project:** `qmail-512809` (Google Auth Platform)
- **App name on the consent screen:** qbitMail. Google rejected "qMail" as too close to "Gmail". The website says that qMail appears as qbitMail.
- **OAuth client:** "qMail macOS", type iOS, bundle ID `com.honzakubita.qmail`
- **Scopes:** `openid`, `email`, `profile` (non-sensitive) and `https://mail.google.com/` (restricted)

## Branding

| Field | Value |
| --- | --- |
| App name | qbitMail |
| App logo | `docs/icon.png`, resized to 120×120 |
| App home page | https://honzakubita.github.io/qMail/ |
| Privacy policy | https://honzakubita.github.io/qMail/privacy.html |
| Terms of service | https://honzakubita.github.io/qMail/terms.html |
| Authorized domain | `honzakubita.github.io` |

The authorized domain has to be verified in [Google Search Console](https://search.google.com/search-console) by a project owner. GitHub Pages serves `honzakubita.github.io/` from a repository named `honzakubita.github.io`, so the verification file goes in that repository, not in this one.

## Restricted scope: the texts for the Verification Center

**How the app uses the restricted scope** (`https://mail.google.com/`):

> qMail (shown as qbitMail on the consent screen) is a native email client for macOS. It connects directly from the user's Mac to Gmail's IMAP server (imap.gmail.com) and SMTP server (smtp.gmail.com) using XOAUTH2. With that connection it downloads the user's email and shows it as chats and threads, keeps a full-text search index on the Mac, and, when the user asks, sends, replies to, forwards, marks, moves, archives and deletes messages. All Google user data stays on the user's Mac: messages and the search index live in the app's sandboxed container, and tokens are kept in the macOS Keychain. qMail has no servers, and no Google user data is sent to the developer or any third party.

**Why narrower scopes aren't enough:**

> Gmail's IMAP and SMTP servers only accept OAuth tokens that include https://mail.google.com/. The narrower Gmail API scopes (gmail.readonly, gmail.modify, gmail.send, gmail.compose) don't grant IMAP or SMTP access. qMail is a standards-based IMAP/SMTP client that works the same way with Gmail, iCloud, Fastmail, Yahoo and any other IMAP provider, so it needs IMAP and SMTP. Its core features also need read, send and delete access: reading mail, sending email the user writes, and moving and deleting messages when the user asks.

**Data storage and the security assessment.** If the form asks whether restricted-scope data is stored on or sent through a server, the answer is **No**. qMail is a local client: data goes only between the user's Mac and Google's servers. Point the reviewers to the "How qMail stores Google user data" and "How qMail shares Google user data" sections of the privacy policy, and to the source code at https://github.com/HonzaKubita/qMail. Google may still require a CASA security assessment (Tier 2, from an authorized lab, renewed every 12 months). If it does, the reviewers will say so by email.

## Demo video (YouTube, visibility Unlisted, in English)

Google requires a video that shows:

1. qMail open on the Mac, then **Settings › Accounts › Add Account › Gmail › Sign in with Google**.
2. Google's sign-in and consent screen with the app name **qbitMail**. **The URL must be visible with `client_id=197154325667-7kf61odgihnhe2eooub9ucl9sfbao3ib.apps.googleusercontent.com` in it.** qMail's sign-in window doesn't show an address bar, so first open the same authorization URL in Safari, zoom in on the address bar, and point to the client ID. Then show the sign-in inside qMail.
3. The consent screen listing "Read, compose, send, and permanently delete all your email from Gmail". Tick it and click Continue.
4. What the scope is used for:
   - email arriving and shown as chats;
   - opening a thread;
   - searching all mail;
   - sending a reply;
   - archiving and deleting a message.
5. Removing the account in Settings › Accounts, and qbitMail in https://myaccount.google.com/permissions.

Use a test Gmail account, not a real mailbox, because the video is seen by Google's reviewers.

## Until verification is done

- **Testing:** only the listed test users (at most 100) can sign in, and their sign-in expires after 7 days.
- **In production, unverified:** anyone can sign in, but Google shows a "Google hasn't verified this app" warning, and the app is limited to 100 users in total.
