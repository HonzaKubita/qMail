#!/usr/bin/env python3
"""Fake IMAP (port 1143) + SMTP (port 1025) server for exercising qMail end to end.

Plaintext, localhost only, any password accepted. Seeds realistic mail: group threads
with References headers, a Czech 1:1 thread, HTML with gmail_quote, an attachment,
newsletters and notifications.
"""
import asyncio
import base64
import email.utils
import re
import sys
import time

ME = ("Honza Test", "me@qmail.test")
ALICE = ("Alice Novak", "alice@example.com")
BOB = ("Bob Smith", "bob@example.com")
CAROL = ("Carol Dvořáková", "carol@example.cz")
DAVE = ("Dave Miller", "dave@example.org")
NEWS = ("Shop Weekly", "news@shop.example")
GITHUB = ("GitHub", "noreply@github.com")

NOW = time.time()
LOG = []
DELIVERED = False


def log(*parts):
    line = " ".join(str(p) for p in parts)
    LOG.append(line)
    print(line, flush=True)


class Msg:
    def __init__(self, uid, raw, flags, date):
        self.uid = uid
        self.raw = raw
        self.flags = set(flags)
        self.date = date

    @property
    def header(self):
        i = self.raw.find(b"\r\n\r\n")
        return self.raw[: i + 4] if i >= 0 else self.raw

    @property
    def text(self):
        i = self.raw.find(b"\r\n\r\n")
        return self.raw[i + 4:] if i >= 0 else b""


MAILBOXES = {}
ATTRS = {
    "INBOX": ["\\HasNoChildren"],
    "Sent": ["\\HasNoChildren", "\\Sent"],
    "Drafts": ["\\HasNoChildren", "\\Drafts"],
    "Archive": ["\\HasNoChildren", "\\Archive"],
    "Junk": ["\\HasNoChildren", "\\Junk"],
    "Trash": ["\\HasNoChildren", "\\Trash"],
    "Projects": ["\\Noselect", "\\HasChildren"],
    "Projects/Ko&AWE-": ["\\HasNoChildren"],
}
for name in ATTRS:
    if "\\Noselect" not in ATTRS[name]:
        MAILBOXES[name] = {"uidvalidity": 7, "uidnext": 1, "messages": []}


def addr(p):
    name, mail = p
    if any(ord(c) > 127 for c in name):
        return "=?UTF-8?B?%s?= <%s>" % (base64.b64encode(name.encode()).decode(), mail)
    return "%s <%s>" % (name, mail)


def add(mbox, raw, flags=(), date=None):
    box = MAILBOXES[mbox]
    uid = box["uidnext"]
    box["uidnext"] += 1
    box["messages"].append(Msg(uid, raw, flags, date or NOW))
    return uid


def make(frm, to, subject, body, minutes_ago, msgid, cc=(), reply_to_ids=(), html=None, attachment=None,
         extra_headers=()):
    date = NOW - minutes_ago * 60
    headers = [
        "From: " + addr(frm),
        "To: " + ", ".join(addr(t) for t in to),
    ]
    if cc:
        headers.append("Cc: " + ", ".join(addr(c) for c in cc))
    subj = subject
    if any(ord(c) > 127 for c in subj):
        subj = "=?UTF-8?B?%s?=" % base64.b64encode(subject.encode()).decode()
    headers += [
        "Subject: " + subj,
        "Date: " + email.utils.formatdate(date, localtime=False),
        "Message-ID: <%s>" % msgid,
        "MIME-Version: 1.0",
    ]
    if reply_to_ids:
        headers.append("In-Reply-To: <%s>" % reply_to_ids[-1])
        headers.append("References: " + " ".join("<%s>" % r for r in reply_to_ids))
    headers += list(extra_headers)

    text_part = body.replace("\n", "\r\n")
    if html is None and attachment is None:
        headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit"]
        raw = "\r\n".join(headers) + "\r\n\r\n" + text_part + "\r\n"
    else:
        boundary = "b-" + msgid.split("@")[0]
        alt = "a-" + msgid.split("@")[0]
        outer_type = "multipart/mixed" if attachment else "multipart/alternative"
        top = boundary if attachment else alt
        headers.append('Content-Type: %s; boundary="%s"' % (outer_type, top))
        parts = []
        alt_body = "--%s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n%s\r\n" % (
            alt, qp(text_part))
        if html:
            alt_body += "--%s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n%s\r\n" % (
                alt, b64lines(html.encode()))
        alt_body += "--%s--\r\n" % alt
        if attachment:
            parts.append('--%s\r\nContent-Type: multipart/alternative; boundary="%s"\r\n\r\n%s' % (boundary, alt, alt_body))
            fname, mime, data = attachment
            parts.append('--%s\r\nContent-Type: %s; name="%s"\r\nContent-Disposition: attachment; filename="%s"\r\nContent-Transfer-Encoding: base64\r\n\r\n%s\r\n' % (
                boundary, mime, fname, fname, b64lines(data)))
            raw = "\r\n".join(headers) + "\r\n\r\n" + "".join(parts) + "--%s--\r\n" % boundary
        else:
            raw = "\r\n".join(headers) + "\r\n\r\n" + alt_body
    return raw.encode("utf-8"), date


def qp(text):
    out = []
    for line in text.split("\r\n"):
        enc = ""
        for b in line.encode("utf-8"):
            if 33 <= b <= 126 and b != 61 or b == 32:
                enc += chr(b)
            else:
                enc += "=%02X" % b
        out.append(enc)
    return "\r\n".join(out)


def b64lines(data):
    s = base64.b64encode(data).decode()
    return "\r\n".join(s[i:i + 76] for i in range(0, len(s), 76))


def seed():
    def put(mbox, frm, to, subject, body, minutes, msgid, seen=True, **kw):
        raw, date = make(frm, to, subject, body, minutes, msgid, **kw)
        add(mbox, raw, ["\\Seen"] if seen else [], date)

    # Group chat: Alice, Bob & me — two subjects.
    put("INBOX", ALICE, [ME, BOB], "Weekend trip to Prague",
        "Hey both!\n\nShould we do Prague next weekend? I found a nice place near Old Town.\n\nAlice", 60 * 50, "t1@example.com")
    put("Sent", ME, [ALICE, BOB], "Re: Weekend trip to Prague",
        "I'm in! Friday evening train works for me.\n\nOn Mon, Alice Novak <alice@example.com> wrote:\n> Should we do Prague next weekend?",
        60 * 49, "t1r1@qmail.test", reply_to_ids=["t1@example.com"])
    put("INBOX", BOB, [ALICE, ME], "Re: Weekend trip to Prague",
        "Count me in too. I can book the tickets tonight 🚆\n\nSent from my iPhone\n\nOn Mon, Feb 3, 2025 at 9:15 AM Honza Test <me@qmail.test> wrote:\n> I'm in!",
        60 * 48, "t1r2@example.com", reply_to_ids=["t1@example.com", "t1r1@qmail.test"])
    put("INBOX", ALICE, [ME, BOB], "Dinner on Friday?",
        "Also — dinner on Friday before we leave? There's a new ramen place by the station: https://example.com/ramen",
        95, "t2@example.com", seen=False)
    put("INBOX", BOB, [ALICE, ME], "Re: Dinner on Friday?",
        "Ramen sounds great. 7pm?", 40, "t2r1@example.com", seen=False, reply_to_ids=["t2@example.com"])

    # 1:1 in Czech with a Czech reply header.
    put("INBOX", CAROL, [ME], "Faktura za září",
        "Ahoj Honzo,\n\nposílám fakturu za září. Dej prosím vědět, jestli je vše v pořádku.\n\nDíky,\nCarol",
        60 * 30, "c1@example.cz")
    put("Sent", ME, [CAROL], "Re: Faktura za září",
        "Díky, vypadá to dobře! Zaplatím do pátku.\n\nDne po 3. 2. 2025 v 9:15 odesílatel Carol <carol@example.cz> napsal:\n> posílám fakturu",
        60 * 29, "c1r1@qmail.test", reply_to_ids=["c1@example.cz"])
    put("INBOX", CAROL, [ME], "Re: Faktura za září", "Super, děkuji! 🙏", 60 * 5, "c1r2@example.cz",
        reply_to_ids=["c1@example.cz", "c1r1@qmail.test"])

    # Bigger group: HTML with gmail_quote and an attachment.
    html = ('<div dir="ltr"><p>Hi team,</p><p>Here is the <b>draft agenda</b> for the offsite. '
            'Please review before Thursday.</p><img src="https://example.com/tracker.png" width="1" height="1">'
            '<p>Dave</p></div><div class="gmail_quote"><div>On Tue Alice wrote:</div><blockquote>old stuff</blockquote></div>')
    put("INBOX", DAVE, [ME, ALICE, BOB], "Team offsite planning",
        "Hi team,\n\nHere is the draft agenda for the offsite. Please review before Thursday.\n\nDave",
        60 * 26, "o1@example.org", cc=[CAROL], html=html,
        attachment=("Offsite agenda.pdf", "application/pdf", b"%PDF-1.4\n% fake pdf for testing\n"))
    put("INBOX", CAROL, [DAVE, ME, ALICE, BOB], "Re: Team offsite planning",
        "Looks good to me. Can we add a session about the Q3 roadmap?", 60 * 3, "o1r1@example.cz", seen=False,
        reply_to_ids=["o1@example.org"])

    # 1:1 unread with Dave.
    put("INBOX", DAVE, [ME], "Coffee next week?", "Free for a coffee on Tuesday? ☕️", 12, "d1@example.org", seen=False)

    # Automated mail — stays out of Chats.
    for i, minutes in enumerate([60 * 70, 60 * 20, 20]):
        put("INBOX", NEWS, [ME], "This week's deals #%d" % (i + 1),
            "Big savings on everything. Unsubscribe anytime.", minutes, "n%d@shop.example" % i, seen=i < 2,
            extra_headers=["List-Unsubscribe: <mailto:unsub@shop.example>", "Precedence: bulk"])
    put("INBOX", GITHUB, [ME], "[qmail] New issue opened", "A new issue was opened in qmail.", 30, "g1@github.com", seen=False)

    put("Archive", ALICE, [ME], "Old photos", "Found these old photos from 2019!", 60 * 24 * 40, "arch1@example.com")
    put("Projects/Ko&AWE-", BOB, [ME], "Project folder test", "This lives in a nested folder with a Czech name.", 60 * 24 * 3, "p1@example.com")


# ---------------------------------------------------------------- IMAP

def parse_set(spec, maximum):
    result = set()
    for part in spec.split(","):
        if ":" in part:
            a, b = part.split(":")
            a = maximum if a == "*" else int(a)
            b = maximum if b == "*" else int(b)
            lo, hi = min(a, b), max(a, b)
            result.update(range(lo, hi + 1))
        else:
            result.add(maximum if part == "*" else int(part))
    return result


def tokenize_items(s):
    s = s.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1]
    items, cur, depth = [], "", 0
    for c in s:
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        if c == " " and depth == 0:
            if cur:
                items.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        items.append(cur)
    return items


def header_fields(msg, names):
    wanted = {n.upper() for n in names}
    out, keep = [], False
    for line in msg.header.split(b"\r\n"):
        if not line:
            continue
        if line[:1] in (b" ", b"\t"):
            if keep:
                out.append(line)
            continue
        name = line.split(b":", 1)[0].decode(errors="replace").upper()
        keep = name in wanted
        if keep:
            out.append(line)
    return b"\r\n".join(out) + b"\r\n\r\n"


def internal_date(ts):
    return time.strftime("%d-%b-%Y %H:%M:%S +0000", time.gmtime(ts))


def literal(data):
    return b"{%d}\r\n" % len(data) + data


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


class IMAPSession:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer
        self.selected = None

    async def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        self.w.write(data)
        await self.w.drain()

    async def run(self):
        await self.send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Fake qMail IMAP ready\r\n")
        while True:
            line = await self.r.readline()
            if not line:
                return
            line = line.rstrip(b"\r\n")
            m = re.match(rb"\{(\d+)\}$", line[-12:]) if line.endswith(b"}") else None
            literal_data = None
            if line.endswith(b"}") and b"{" in line:
                n = int(line[line.rfind(b"{") + 1:-1].rstrip(b"+"))
                if not line[:-1].endswith(b"+"):
                    await self.send("+ Ready for literal\r\n")
                literal_data = await self.r.readexactly(n)
                await self.r.readline()
                line = line[: line.rfind(b"{")].rstrip()
            text = line.decode("utf-8", errors="replace")
            parts = text.split(" ", 2)
            if len(parts) < 2:
                await self.send("* BAD Missing command\r\n")
                continue
            tag, cmd = parts[0], parts[1].upper()
            args = parts[2] if len(parts) > 2 else ""
            log("IMAP <", tag, cmd, args[:120] if cmd not in ("LOGIN",) else "***")
            try:
                done = await self.dispatch(tag, cmd, args, literal_data)
                if done:
                    return
            except Exception as exc:  # noqa
                log("IMAP error", repr(exc))
                await self.send("%s BAD %s\r\n" % (tag, exc))

    async def dispatch(self, tag, cmd, args, literal_data):
        if cmd == "CAPABILITY":
            await self.send("* CAPABILITY IMAP4rev1 MOVE UIDPLUS IDLE AUTH=PLAIN\r\n%s OK CAPABILITY completed\r\n" % tag)
        elif cmd == "LOGIN":
            await self.send("%s OK [CAPABILITY IMAP4rev1 MOVE UIDPLUS] Logged in\r\n" % tag)
        elif cmd == "AUTHENTICATE":
            await self.send("+ \r\n")
            await self.r.readline()
            await self.send("%s OK Logged in\r\n" % tag)
        elif cmd == "IDLE":
            global DELIVERED
            await self.send("+ idling\r\n")
            done_task = asyncio.ensure_future(self.r.readline())
            if not DELIVERED and self.selected == "INBOX":
                delay = asyncio.ensure_future(asyncio.sleep(4))
                finished, _ = await asyncio.wait({done_task, delay}, return_when=asyncio.FIRST_COMPLETED)
                if delay in finished and not done_task.done():
                    DELIVERED = True
                    raw, date = make(ALICE, [ME, BOB], "Re: Dinner on Friday?", "Perfect, see you there! 🎉\n\nOn Sun, Honza Test wrote:\n> 7pm works!",
                                     0, "t2r3@example.com", reply_to_ids=["t2@example.com", "t2r1@example.com"])
                    add("INBOX", raw, [], time.time())
                    log("IDLE: delivered new message")
                    await self.send("* %d EXISTS\r\n" % len(self.box()))
            await done_task
            log("IDLE: DONE received")
            await self.send("%s OK IDLE terminated\r\n" % tag)
        elif cmd == "NOOP":
            await self.send("%s OK NOOP\r\n" % tag)
        elif cmd == "LOGOUT":
            await self.send("* BYE bye\r\n%s OK LOGOUT\r\n" % tag)
            return True
        elif cmd == "LIST":
            out = ""
            for name, attrs in ATTRS.items():
                out += '* LIST (%s) "/" %s\r\n' % (" ".join(attrs), quote(name))
            await self.send(out + "%s OK LIST completed\r\n" % tag)
        elif cmd in ("SELECT", "EXAMINE"):
            name = args.strip().strip('"')
            if name.upper() == "INBOX":
                name = "INBOX"
            if name not in MAILBOXES:
                await self.send("%s NO No such mailbox\r\n" % tag)
                return
            self.selected = name
            box = MAILBOXES[name]
            await self.send(
                "* FLAGS (\\Seen \\Flagged \\Answered \\Deleted \\Draft)\r\n"
                "* %d EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY %d] UIDs valid\r\n* OK [UIDNEXT %d] Predicted\r\n"
                "%s OK [READ-WRITE] SELECT completed\r\n" % (len(box["messages"]), box["uidvalidity"], box["uidnext"], tag))
        elif cmd == "FETCH":
            await self.fetch(tag, args, uid_mode=False)
        elif cmd == "UID":
            sub, rest = (args.split(" ", 1) + [""])[:2]
            sub = sub.upper()
            if sub == "FETCH":
                await self.fetch(tag, rest, uid_mode=True)
            elif sub == "STORE":
                await self.store(tag, rest)
            elif sub in ("MOVE", "COPY"):
                await self.move(tag, rest, copy=sub == "COPY")
            elif sub == "EXPUNGE":
                await self.expunge(tag, rest)
            elif sub == "SEARCH":
                await self.search(tag, rest)
            else:
                await self.send("%s BAD Unknown UID command\r\n" % tag)
        elif cmd == "EXPUNGE":
            await self.expunge(tag, None)
        elif cmd == "APPEND":
            name = re.match(r'"([^"]+)"|(\S+)', args)
            name = name.group(1) or name.group(2)
            flags = re.search(r"\(([^)]*)\)", args)
            flags = flags.group(1).split() if flags else []
            uid = add(name, literal_data, flags, time.time())
            log("APPEND", name, "uid", uid, len(literal_data), "bytes")
            await self.send("%s OK [APPENDUID %d %d] APPEND completed\r\n" % (tag, MAILBOXES[name]["uidvalidity"], uid))
        else:
            await self.send("%s BAD Unsupported %s\r\n" % (tag, cmd))

    def box(self):
        return MAILBOXES[self.selected]["messages"]

    async def fetch(self, tag, args, uid_mode):
        spec, items_str = args.split(" ", 1)
        msgs = self.box()
        if uid_mode:
            max_uid = msgs[-1].uid if msgs else 0
            uids = parse_set(spec, max_uid)
            if spec.endswith(":*") and msgs:
                uids.add(max_uid)
            selected = [(i + 1, m) for i, m in enumerate(msgs) if m.uid in uids]
        else:
            seqs = parse_set(spec, len(msgs))
            selected = [(i + 1, m) for i, m in enumerate(msgs) if (i + 1) in seqs]
        items = tokenize_items(items_str)
        out = b""
        for seq, m in selected:
            parts = [b"UID %d" % m.uid]
            for item in items:
                up = item.upper()
                if up == "UID":
                    continue
                if up == "FLAGS":
                    parts.append(("FLAGS (%s)" % " ".join(sorted(m.flags))).encode())
                elif up == "INTERNALDATE":
                    parts.append(('INTERNALDATE "%s"' % internal_date(m.date)).encode())
                elif up == "RFC822.SIZE":
                    parts.append(b"RFC822.SIZE %d" % len(m.raw))
                elif up.startswith("BODY"):
                    peek = up.startswith("BODY.PEEK")
                    section = item[item.find("[") + 1: item.rfind("]")]
                    partial = re.search(r"<(\d+)\.(\d+)>$", item)
                    if section.upper().startswith("HEADER.FIELDS"):
                        names = section[section.find("(") + 1: section.rfind(")")].split()
                        data = header_fields(m, names)
                        label = "BODY[%s]" % section
                    elif section.upper() == "TEXT":
                        data = m.text
                        label = "BODY[TEXT]"
                    elif section.upper() == "HEADER":
                        data = m.header
                        label = "BODY[HEADER]"
                    else:
                        data = m.raw
                        label = "BODY[]"
                    if partial:
                        start, length = int(partial.group(1)), int(partial.group(2))
                        data = data[start:start + length]
                        label += "<%d>" % start
                    if not peek:
                        m.flags.add("\\Seen")
                    parts.append(label.encode() + b" " + literal(data))
            out += b"* %d FETCH (" % seq + b" ".join(parts) + b")\r\n"
        await self.send(out + ("%s OK FETCH completed\r\n" % tag).encode())

    async def store(self, tag, rest):
        spec, op, flags = re.match(r"(\S+) (\S+) \(([^)]*)\)", rest).groups()
        uids = parse_set(spec, self.box()[-1].uid if self.box() else 0)
        for m in self.box():
            if m.uid in uids:
                if op.upper().startswith("+"):
                    m.flags.update(flags.split())
                else:
                    m.flags.difference_update(flags.split())
        log("STORE", self.selected, spec, op, flags)
        await self.send("%s OK STORE completed\r\n" % tag)

    async def move(self, tag, rest, copy):
        spec, dest = rest.split(" ", 1)
        dest = dest.strip().strip('"')
        msgs = self.box()
        uids = parse_set(spec, msgs[-1].uid if msgs else 0)
        moving = [m for m in msgs if m.uid in uids]
        out = ""
        for m in moving:
            add(dest, m.raw, m.flags, m.date)
        if not copy:
            for m in sorted(moving, key=lambda x: -msgs.index(x)):
                out += "* %d EXPUNGE\r\n" % (msgs.index(m) + 1)
                msgs.remove(m)
        log("MOVE" if not copy else "COPY", self.selected, "->", dest, [m.uid for m in moving])
        await self.send(out + "%s OK done\r\n" % tag)

    async def expunge(self, tag, spec):
        msgs = self.box()
        uids = parse_set(spec, msgs[-1].uid if msgs else 0) if spec else None
        out = ""
        for m in list(reversed(msgs)):
            if "\\Deleted" in m.flags and (uids is None or m.uid in uids):
                out += "* %d EXPUNGE\r\n" % (msgs.index(m) + 1)
                msgs.remove(m)
        await self.send(out + "%s OK EXPUNGE completed\r\n" % tag)

    async def search(self, tag, rest):
        needle = re.findall(r'"([^"]*)"', rest)
        needle = needle[-1].lower() if needle else ""
        hits = [str(m.uid) for m in self.box() if needle.encode() in m.raw.lower()]
        await self.send("* SEARCH %s\r\n%s OK SEARCH completed\r\n" % (" ".join(hits), tag))


async def imap_client(reader, writer):
    log("IMAP connection")
    try:
        await IMAPSession(reader, writer).run()
    except (ConnectionResetError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


# ---------------------------------------------------------------- SMTP

async def smtp_client(reader, writer):
    async def send(s):
        writer.write(s.encode())
        await writer.drain()

    log("SMTP connection")
    await send("220 fake.qmail.test ESMTP ready\r\n")
    sender, rcpts = None, []
    try:
        while True:
            line = await reader.readline()
            if not line:
                return
            cmd = line.decode(errors="replace").rstrip("\r\n")
            up = cmd.upper()
            log("SMTP <", cmd if not up.startswith("AUTH") else "AUTH ***")
            if up.startswith("EHLO") or up.startswith("HELO"):
                await send("250-fake.qmail.test\r\n250-AUTH PLAIN LOGIN\r\n250-8BITMIME\r\n250 SIZE 35882577\r\n")
            elif up.startswith("AUTH"):
                await send("235 2.7.0 Authentication successful\r\n")
            elif up.startswith("MAIL FROM"):
                sender = cmd[10:]
                rcpts = []
                await send("250 OK\r\n")
            elif up.startswith("RCPT TO"):
                rcpts.append(cmd[8:])
                await send("250 OK\r\n")
            elif up == "DATA":
                await send("354 End data with <CR><LF>.<CR><LF>\r\n")
                data = b""
                while True:
                    l = await reader.readline()
                    if l == b".\r\n":
                        break
                    if l.startswith(b".."):
                        l = l[1:]
                    data += l
                log("SMTP message from", sender, "to", rcpts, len(data), "bytes")
                with open(OUTBOX, "ab") as f:
                    f.write(b"=== MESSAGE ===\r\n" + data)
                await send("250 OK queued\r\n")
            elif up == "QUIT":
                await send("221 Bye\r\n")
                return
            else:
                await send("250 OK\r\n")
    finally:
        writer.close()


OUTBOX = sys.argv[1] if len(sys.argv) > 1 else "/tmp/qmail-outbox.eml"


async def main():
    seed()
    imap = await asyncio.start_server(imap_client, "127.0.0.1", 1143)
    smtp = await asyncio.start_server(smtp_client, "127.0.0.1", 1025)
    log("Fake IMAP on 1143, SMTP on 1025")
    async with imap, smtp:
        await asyncio.gather(imap.serve_forever(), smtp.serve_forever())


if __name__ == "__main__":
    asyncio.run(main())
