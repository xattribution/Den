# Onboarding: getting a family and its devices in

Den is a calendar and a shopping list, not a bank vault, and in the private setup the network
is already a gate (only the family's homes and their Tailscale reach the hub). So the goal is
the fewest taps that still leave a stranger with nothing: an invite is a parent's approval given
ahead of time, for one device, for a day, and the parents always hear when it was used.

## What others do

| Product | How a device or person gets in | What we take |
| --- | --- | --- |
| Tailscale | Device approval is off unless an admin turns it on; an admin can mint a *pre-approved*, single-use or reusable, expiring auth key, and "the device is automatically approved" ([device approval](https://tailscale.com/docs/features/access-control/device-management/device-approval.md)). Share links: "treat the invite link the way you would a password" ([sharing](https://tailscale.com/kb/1084/sharing)) | Pre-approved, single-use, expiring keys made by an admin |
| Bitwarden, Vaultwarden | Email invite (5 days), the person accepts, then an admin *confirms*, comparing a fingerprint phrase, before the organization's key is shared ([members](https://bitwarden.com/help/managing-users/)) | Den's old Approve tap is this step; a pre-approved key removes it, a fingerprint in the setup link replaces comparing words |
| Jellyfin | Quick Connect: the new device shows a code, a signed-in device enters it ([docs](https://jellyfin.org/docs/general/server/quick-connect)) | Den's "show a code on the computer" stays as the fallback |
| Immich | The admin creates each account; an optional welcome email ([docs](https://docs.immich.app/administration/user-management)) | Nothing: no per-person passwords in Den |
| Home Assistant | The owner makes an account in the browser; the companion app finds the server and signs in ([Nabu Casa](https://support.nabucasa.com/hc/en-us/articles/24737667232413)) | One link from the server's own output for the first parent |
| Apple Family Sharing, Google Family Link | The organizer invites in Messages or in person; accepting is the approval; a parent sets up a child's device | Accepting the invite is enough; the parent decided when they sent it |
| Cozi, OurHome | Email invites into accounts with passwords | Nothing: passwords are what we're avoiding |
| Magic links, passkeys | A link signs in with one tap, but on iOS it opens in Safari, never in an installed web app, so apps fall back to a typed code ([Ghost forum](https://forum.ghost.org/t/working-on-moving-my-theme-to-a-pwa-magic-link-challenges/23147)). Passkeys sign a person into a server account; Den has none (each device has its own key) | The link must reach the Home Screen app some other way; the four words stay as the typed code |

## iOS Home Screen web apps (what decides what's possible)

- **Storage is separate from Safari's**, by design: "Home Screen apps are created as isolated
  entities without shared state with the browser" ([WebKit bug 181849](https://bugs.webkit.org/show_bug.cgi?id=181849)).
- **Cookies are copied once, when the app is added** (iOS and iPadOS 17.2 and later), and nothing
  else: "the cookies are copied over… No other kind of local storage is copied over"
  ([WebKit, Safari 17.2](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/)).
- **The manifest's `start_url` is honored**, so the page's own URL and its fragment don't carry
  into the app; with no `start_url` the page you added from is used (developer reports, Oct
  2026: [1](https://github.com/An-Be/your-turn/pull/3), [2](https://github.com/kashyap07/kashyapsuhas.com/pull/36),
  [3](https://github.com/uzayr-iqbal-hamid/hypr-remote/issues/1)). Den keeps its `start_url`: a
  secret in the icon's URL would live as long as the icon.
- **A tapped link always opens Safari**, never the installed app.
- **iOS 26** opens every site added to the Home Screen as a web app by default
  ([WebKit](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/)),
  and its compact Safari bar keeps Share behind the three dots.

So Safari's page for an invite (or the setup link) keeps the link's route in a first-party
cookie for a day, and the Home Screen app takes it and clears it on its first start. Confidence:
medium-high. The behavior is Apple's documented one, but this hasn't been tried on a real
iPhone yet. When it doesn't happen (iOS before 17.2, or Den already on the Home Screen), the page
offers **Copy invite** above the steps and Den's welcome offers **Paste an invite**, and the
four words are still on the page to type.

## What Den does

- **Invites let people in.** A parent's own phone picks four words, writes an `inviteKey`
  record (the public half of a key the words stretch to: "this key may let in one device as
  Grandma's, until tomorrow") and sends the link. Grandma's new iPhone derives the same key,
  proves it to the hub with one pairing message, and approves itself. Validity accepts that once,
  only while the inviting parent is still a parent with that phone, and before it expires
  (ARCHITECTURE.md, "Invite keys"). Every parent's own device then shows "Grandma Rosa joined on
  an iPhone" with **Got it** and **That wasn't Grandma Rosa**. **Let them in right away** is on by
  default; off, a parent approves on Today as before.
- **The first parent types no code.** `den_hub setup-link` (and the private `install.sh`) prints a
  link and a QR code holding the setup code and the hub's device id. The phone takes in only the
  hub whose key that id is the hash of, so there are no words to compare.
- **One step per screen.** A link opens the step it's for. Safari shows the Home Screen steps with
  a picture of where Share is. The device names itself ("Grandma Rosa's iPhone"). The recovery
  words wait in Needs you instead of blocking setup.
- **A computer:** **Open Den on your computer** on the parent's phone shows their own link (type
  it, Send it, or scan it); the browser is in as them when it opens it.

Taps, counted from the first tap on the phone, with the iPhone's Share button visible (iOS 26's
compact bar adds a tap behind the three dots, before and after):

| Flow | Before | After |
| --- | --- | --- |
| First parent | Type the address, then 8 taps (Share, Add to Home Screen, Add, open Den, Start a family, Create family, I wrote them down, Go to Today); type an 8-letter code (a native app: compare 3 words too) | Scan the QR code, then 7 taps (the code's link, Share, Add to Home Screen, Add, open Den, Create family, Go to Today); nothing to type but the names |
| Everyone else | 7 taps and 4 words typed, or 9 taps with Paste (the link, Share, Add to Home Screen, Add, open Den, Join your family, Paste, iOS's Paste, Join the family), then wait for a parent's tap | 6 taps (the link, Share, Add to Home Screen, Add, open Den, Join as Grandma Rosa), nothing typed, no waiting |
| A browser on a computer | Type the address and click Link; on the phone 3 taps, scan the screen, then Approve | On the phone 4 taps (Family, you, Add a computer, Send); on the computer open the link and click Join |

## The trade-offs, in plain words

- **Whoever has the link (or the four words) in the next day can join as that person, once.**
  Before, they could only ask; a parent decided. That's the cost of no waiting. What limits it:
  the hub must be reachable (in the private setup, only from home or Tailscale); it works once,
  so if someone else got in first, the real person's link stops working, which is noticed; it
  ends in 24 hours; every parent is told at once, and **That wasn't them** removes the device.
  For an invite that should wait, turn off **Let them in right away**.
- **A parent's invite ends with them.** Removing that parent, making them anything else, or
  removing the phone that made it takes the key away, even from a device that backdates its
  clock.
- **The hub never learns the words.** It keeps a word invite under a stretched slot it can't run
  back within the invite's day, and only sees the proof. A web app it serves sees what the page
  holds, as it always could (ARCHITECTURE.md, "The web app").
- **Four words are guessable only online**, and only slowly: wrong words or keys count against
  each address and against everyone (10 and 200 in 10 minutes).
- **The setup link is the setup code** plus the hub's identity: whoever opens it first, where the
  hub can be reached, starts the family on that hub. Print it on the server; send it nowhere.
- **The cookie** that carries a link from Safari to the Home Screen app is first-party, lives at
  most a day, is cleared on first use, and reaches only the hub that served the page.
