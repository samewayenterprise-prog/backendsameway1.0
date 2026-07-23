# Changelog — in plain English

This file explains every change to the SameWay backend in normal
language, not code-speak. If you're not a developer, start here instead
of the commit history. Newest entries are at the top.

Each entry links to the real commit if you want to see the actual code.

---

## 2026-07-23 — "Checked: the website can browse rides without any backend changes"

While building the website's ride search, we audited whether the
backend needed changes to let logged-out visitors browse rides. Good
news: it didn't — the security rules were already designed for this
from day one. Anyone can see published rides, driver names, photos
and ratings; nobody can see phone numbers, documents, or anything
private; and booking without signing in is impossible (we tried — it
fails hard, as it should).

We proved this by running an exact local copy of the production
system — same database rules, same API layer — and attacking it from
both sides: as a logged-out stranger and as a signed-in rider. One
real booking went through correctly, seat counts updated, and the
fair-price cap even rejected one of our own test rides for being
priced 26 qəpik too high. No code changed in this commit — this is
the written record of what was checked and found.

One item flagged for a future decision (not urgent): the current
rules let anyone see an active car's plate number before booking. The
website deliberately doesn't show plates, but we should consciously
decide whether the rule itself should be tighter.

---

## 2026-07-23 — "One login for the whole admin panel, not two"
Commit: [`adb7e8e`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/adb7e8e)

You pushed back, correctly — the new "All Tables" page had its own
separate login screen, meaning you'd log into the admin panel, then
get asked to log in *again* just for that one page. That made it feel
like two different products stuck together instead of one real admin
backend. Fixed: log in once, and "All Tables" now just works, no
second password prompt. We also pushed our real brand colors (the
same violet and blue used everywhere else) into that page.

To be fully honest about the limits here: the single login is genuinely
fixed and tested. The colors are set up correctly but we haven't
visually confirmed them in a real browser yet — that specific check
needs a person looking at it, not just our usual testing. And making
this page look 100% identical to our other hand-built pages — exact
same layout, same fonts — isn't realistically possible without
building all ~30 remaining table pages by hand ourselves, which is the
slow manual work this whole feature exists to avoid in the first
place.

---

## 2026-07-23 — "The scary-looking login page was just your browser's memory playing tricks"
Commit: [`0cb76e1`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/0cb76e1)

You saw the new "All Tables" login page showing generic third-party
branding instead of SameWay's — turned out to be a false alarm caused
by your browser holding onto an old cached copy of that page from
earlier while we were still fixing the connection settings. A hard
refresh clears it. While double-checking, we did fix one small real
mistake: a setting meant to hide a little "made with" credit line at
the bottom of that page had a typo in its name, so it was silently
doing nothing. Fixed.

---

## 2026-07-23 — "Added a page that shows every single table in our database"
Commit: [`ca0c430`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/ca0c430)

You showed a screenshot of another project's admin panel — one page
listing every database table with Add/Change buttons, built
automatically. We had nothing like that. Our admin panel only had
hand-built pages for the specific things we designed for (KYC review,
reports, markets), leaving about 30 other tables — vehicles, routes,
ranks, badges, streaks, device tokens, and more — with zero visibility
for anyone running the business day to day.

This adds that missing page, at "All Tables" in the admin panel. Point
it at the real database and it builds view/edit/add/delete screens for
every table automatically — no page-by-page coding needed.

Three safety rules keep this from undoing the careful work we did
earlier today: some tables (vehicles, device tokens) are fully
editable, since fixing a typo there is safe. Some (transactions,
payouts, bookings) are view-only — you can look, but can't edit them
here directly, because those must only ever change through the proper
flow (a payment confirming, a booking request), never a manual
shortcut. And one table (people's ID verification documents) is
hidden completely — the existing ID-review page already handles that
correctly, and a shortcut around it would defeat the whole point of
actually checking someone's ID before approving them.

While building this we found and fixed two real bugs in the
open-source tool we used, both stemming from the same root cause: it
wasn't accounting for how Supabase names things internally, which
would have silently broken the single most important table — Users —
the moment it touched our real database, with no error to warn anyone.
We fixed the actual bugs (not a workaround) and proved the fix survives
a completely fresh install, not just the machine we built it on.

---

## 2026-07-23 — "The 'ask the driver' feature is now actually live on the server"

The "ask a quick question before you book" feature below was written
and saved, but when we went to switch it on, the database refused it on
a technicality — the change introduced a new category of conversation
and tried to use that new category in the very same step that created
it, which the database doesn't allow. The fix was simply splitting it
into two steps: first teach the database the new category exists, then
build everything that uses it. Both steps are now live, and we tested
the real behavior end to end: asking a question works, asking a second
question joins the same chat instead of starting a new one, two
different riders get separate chats, and a driver can't "ask a
question" on their own ride. All 28 security checks still pass.

## 2026-07-23 — "Ask the driver a quick question before you book"
Commit: [`1fe5db7`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/1fe5db7)

Found by comparing directly against BlaBlaCar again: there's a
"Negotiate" button on a ride, separate from "Book," that lets you ask
the driver something quick first — a different meeting spot, a
different drop-off, or just to say hi — before you've committed to
anything. We checked our app and had nothing like this at all: the only
way to message a driver was after you'd already requested a seat.

This adds that missing earlier step. Pick a quick question type, send
it (you can edit the pre-filled text), and you land in a normal chat
with the driver — no booking attached, no commitment. Ask a second
question later on the same ride and it goes into that same
conversation instead of starting a brand new one each time.

## 2026-07-23 — "Fixed: publishing a ride or route was completely broken"

A bug in the fair-price protection we shipped earlier today accidentally
broke publishing entirely: any driver trying to post a new ride or a new
recurring route got an error, every single time. The fair-price check —
the one that stops someone from charging, say, 9999 manat for a Baku
trip — was written in a way that made the database reject the post
before it even looked at the price.

This fixes that. Publishing works again, and we tested it both ways: a
normally-priced Baku→Ganja trip goes through, and an absurdly overpriced
one is still correctly refused with a clear message explaining SameWay
is about sharing costs, not making a profit off passengers. We also
re-ran our full 28-point security check afterwards — all 28 still pass.

## 2026-07-23 — "You can now see who else is riding with you"
Commit: [`0008873`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/0008873)

We compared our app directly against BlaBlaCar and found something
they do that we didn't: on any ride — even one that already happened
weeks ago — you can see everyone else who's also riding along, even if
they booked as a totally separate group from you. Like seeing "Oliwia +
1 friend" also in the car, with a link to her profile where you can
rate her, message her, or report her if something was off.

We checked our app and realized we only ever showed you your *own*
group — never anyone else sharing the ride. That's a real trust gap,
since "who am I riding with" is exactly the kind of thing that makes
people feel safe using a carpooling app. This fixes it. It works on old
completed rides too, not just upcoming ones.

While building this, we also double-checked three related things and
confirmed they already worked correctly and didn't need fixing: you can
already message your driver on old rides, you can already rate someone
from an old ride, and you can already report someone regardless of
whether you're in their booking group. Only the "see who else is here"
part was actually missing.

---

## 2026-07-23 — "Don't let drivers overcharge, and don't pressure tired drivers into driving"
Commit: [`dec628f`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/dec628f)

Three things changed behind the scenes. Nothing customer-facing yet —
there's still no real money moving and no live users. This is
foundation work before real people start using the app.

**1. Drivers can no longer charge more than a fair share of the trip.**
Think of it like a friend driving you somewhere and splitting gas money
— totally normal, no license needed. But if they start charging you
like a taxi and pocketing extra, that's suddenly an illegal taxi
business in most countries. So we built a rule that calculates "what
would gas + car wear-and-tear actually cost for this trip?" and a
driver **cannot charge more than that**, split fairly across everyone
in the car. We also added a friendly helper that tells drivers "hey,
other people are charging less on this route — you might not get
booked," like a price-comparison tool. That second part is just a
suggestion; the first part is a hard rule the app enforces.

*While building this, we actually caught our own math letting drivers
overcharge in some cases (like a big van with lots of seats). We fixed
it and triple-checked before shipping.*

**2. The driving "streak" no longer pressures tired drivers.**
The app has a game-like streak feature (similar to Duolingo's daily
streak) that rewards drivers for driving a route regularly. It used to
only count if you actually completed the drive — which is risky, since
a tired driver might think "I have to drive tonight or I lose my whole
streak" and drive anyway when they shouldn't. Now the streak counts for
just *offering* to drive, not for completing the trip. Cancelling
because you're tired costs nothing.

**3. A handful of "make sure the computer double-checks itself" fixes.**
So the app can't accidentally sell the same seat twice, can't let
someone join a group booking after time's run out, and stays fast even
as more people use it.

---

## 2026-07-23 — "Locked the money tables, and got the security tests actually running"
Commit: [`e4c3d4f`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/e4c3d4f)

We wrote a set of automated tests earlier whose whole job is to try to
break in — pretend to be one user and attempt to read another user's
private data (phone number, ID documents, payment history) and confirm
the app says no every time. Those tests had never actually been run
before. This is the entry where we finally ran them for real.

Good news: 26 out of 28 checks passed immediately. Two didn't — not
because data was actually exposed, but because two tables that hold
money information (transaction records and driver balances) still had
some old default permissions sitting around that *could* have caused
problems in the future if a mistake was made elsewhere. We locked those
down. All 28 checks pass now.

---

## 2026-07-23 — "Every country in the world, with an on/off switch"
Commit: [`d3fef0e`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/d3fef0e)

Added every country and territory in the world (249 of them) into the
system, grouped by region, each with a simple on/off switch controlled
from the admin panel. Right now only Azerbaijan is switched "on" —
every other country is present but inactive, so opening a new market
later is a matter of flipping a switch, not writing new code.

---

## 2026-07-23 — "Added the merging-arrow logo to the admin site"
Commit: [`0190fb6`](https://github.com/samewayenterprise-prog/backendsameway1.0/commit/0190fb6)

Purely visual — the admin panel (the internal tool used to review
driver documents, handle reports, etc.) now shows the real SameWay logo
instead of plain text, and the browser tab shows the little icon too.

---

*Earlier history (schema, payments, gamification engine, admin panel
build, RLS policies) predates this changelog — see the full commit
history on GitHub for those.*
