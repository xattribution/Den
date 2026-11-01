# Den

The family's calendar, chores, lists and points, in one app on everyone's phone.

![Den's Today on an iPad and a phone: what needs you (a ride nobody is driving, a reward to approve, a late chore), today's events, and chores by person](docs/screens/today-ipad-and-phone.png)

Den runs on a computer you own, not on someone else's service. This page shows how to set that up,
step by step. You don't need to know anything about servers. It takes about 30 minutes, most of
it waiting.

- [What you need](#what-you-need)
- [Step 1: Cloudflare](#cloudflare) (so the family can reach Den from anywhere)
- [Step 2: Install Den](#step-2-install-den)
- [Step 3: Give Den its address in Cloudflare](#step-3-give-den-its-address-in-cloudflare)
- [Step 4: Make your family](#step-4-make-your-family)
- [Backups, and your NAS](#backups-and-your-nas)
- [Updates](#updates)
- [Moving Den to another computer](#moving-den-to-another-computer)
- [If something goes wrong](#if-something-goes-wrong)

## What you need

1. **A computer that stays on.** Any one of these works:
   - an old PC or laptop, a mini PC, or a Raspberry Pi 4 or 5, at home, or
   - a VPS: a small server you rent online (from Hetzner, DigitalOcean, Linode and others, for a
     few dollars a month).

   It needs **Linux** on it, the 64-bit kind: Ubuntu, Debian, Raspberry Pi OS (64-bit), Fedora
   and most others work. It needs at least **1 GB of memory** and **2 GB of free space**. If
   you're renting a VPS, pick **Ubuntu** when it asks; that's the safe choice.

   Nothing else on it needs setting up. Den's installer puts in everything it needs.

2. **A free Cloudflare account**, at [cloudflare.com](https://dash.cloudflare.com/sign-up).
   Cloudflare is what lets your family's phones reach Den from anywhere, safely, without you
   changing anything on your router.

3. **A web address (a domain)**, like `smithfamily.com`. Den will live at an address under it,
   like `den.smithfamily.com`. If you don't have one, you can buy one inside Cloudflare (about
   $10 a year): in Cloudflare, open **Domains**, then **Buy a domain** (it may be called
   **Register domains**). If you already have one somewhere else, Cloudflare's **Add a domain**
   button walks you through moving it over; that part can take a few hours to finish, so do it
   first.

4. **About 30 minutes.**

<a id="cloudflare"></a>

## Step 1: Cloudflare

Here you make a **tunnel**: a private line from your computer to Cloudflare. You'll come away with
a long code called a **tunnel token**.

1. Sign in at [dash.cloudflare.com](https://dash.cloudflare.com).
2. In the menu on the left, open **Networking**, then **Tunnels**.
   (On some accounts it's under **Zero Trust**, then **Networks**, then **Tunnels**.)
3. Click **Create Tunnel**. If it asks what kind, pick **Cloudflared**.
4. Give it a name, like `den`, and click **Create Tunnel** (or **Save tunnel**).
5. Cloudflare now shows some commands to install something. **Don't run them.** Den does that
   part itself. Just copy one of the commands: click the copy button next to it.

   The command has your tunnel token in it: a long code starting with `eyJ`. You can paste the
   whole command into Den later; Den finds the token in it.

   Keep this page open. You'll come back to it in Step 3.

**Keep the token private.** Anyone with it can pretend to be your Den. If it ever gets out, delete
the tunnel in Cloudflare and make a new one.

## Step 2: Install Den

1. **Open a terminal on your computer.** That's the window where you type commands.
   - On a VPS: on your provider's website, open your server and click **Console** (some call it
     **Launch console** or **Web console**). Sign in as `root` with the password they gave you.
   - On a computer at home with a screen: open the **Terminal** app.
   - On a computer at home without a screen: from another computer, open a terminal and type
     `ssh` followed by your username, `@` and the computer's address, like
     `ssh pi@192.168.1.50`.

2. **Copy this line, paste it into the terminal, and press Enter:**

   ```sh
   curl -fsSL https://github.com/xattribution/Den/releases/latest/download/install.sh | sudo sh
   ```

   If it asks for a password, type your password for that computer (nothing shows as you type;
   that's normal) and press Enter.

3. **Wait.** It goes through 5 steps and tells you what it's doing. The first time takes 5 to 15
   minutes.

4. **When it asks for the tunnel token, paste what you copied in Step 1 and press Enter.** (In
   most terminals, paste is right-click, or Ctrl+Shift+V.) If you skip it, you can give it
   later by typing `sudo den tunnel`.

5. At the end it says **Den is running**, then shows a link and a square code (a QR code). Leave
   the terminal open and go on to Step 3.

## Step 3: Give Den its address in Cloudflare

Back on the Cloudflare page from Step 1:

1. Click **Continue** (or **Next**). If you closed the page: **Networking**, then **Tunnels**,
   then click your tunnel's name.
2. Find **Routes** (or **Public hostnames**) and click **Add route** (or **Add a public
   hostname**). If it asks what kind, pick **Published application**.
3. Fill it in:
   - **Subdomain:** `den`
   - **Domain:** pick your domain from the list
   - **Service URL:** `http://hub:47733`

     If the page has two boxes instead, set **Type** to `HTTP` and **URL** to `hub:47733`.
4. Click **Add route** (or **Save**).

Type it exactly as shown: `hub`, not `localhost` and not your computer's address.

That's your family's address: `den.` plus your domain, like `den.smithfamily.com`.

## Step 4: Make your family

1. On your phone or computer, open the link the installer showed at the end of Step 2. Or point
   your phone's camera at the square code and tap the link that appears.
   - Lost it? In the terminal, type `sudo den setup-link` and press Enter for a new one.
2. If Den asks for the tunnel token, paste it and click **Connect**. When it says **Connected**,
   it shows your family's address. If it asks what address you gave it in Cloudflare, type the
   address from Step 3.
3. Click **Make your family**, then follow the page: it shows a code to scan with your phone, and
   you finish on your phone.
4. **On an iPhone:** when Den opens in Safari, tap the **Share** button (the square with an arrow),
   then **Add to Home Screen**, then **Add**. From then on, open Den from its icon on the Home
   Screen, like any app.

   **On Android:** in Chrome, tap the **⋮** menu, then **Add to Home screen** or **Install app**.

5. **Save your recovery words.** They're 12 words that get you back in if you lose your phone, and
   they're also what opens your backups. In Den: tap your picture at the top, then **Family**,
   then your own name, then **Recovery words**. Save them to your phone's passwords, or write them
   down and keep them somewhere safe. Every parent should do this.

**Adding the rest of the family:** in Den, tap your picture at the top, then **Invite someone**.
Send them the link. They open it, add Den to their Home Screen the same way, and they're in.
Only people you invite can get in.

**A kitchen tablet:** on the tablet, open your family's address and choose **Set up as a kitchen
screen**. It shows a code. On your phone: **Settings**, **Kitchen screen**, **Add a screen**, and
type the code.

## Backups, and your NAS

Den backs up your family **every night** on its own, and keeps the newest 14. You don't need to do
anything. Any parent's **recovery words** open a backup. If no parent has saved recovery words,
Den can't make backups, and Settings, **Backups** says so.

**To also keep a copy on a NAS at home** (a Synology, QNAP or similar):

1. On the NAS, make sure **file sharing (SMB)** is on, and make a shared folder for backups if you
   don't have one. Your NAS's own settings have both.
2. In Den on your phone: **Settings**, **Backups**, **Back up to a NAS**.
3. Type your NAS's name or address (like `nas.local` or `192.168.1.20`), then a username and
   password for the NAS.
4. Pick the shared folder. Den makes a test copy, and if that works, it saves.

From then on, every night's backup goes to the NAS too. If the NAS can't be reached, Den tells you
once, and the server still keeps its own copy.

**Back up now:** Settings, **Backups**, **Back up now**.

## Updates

Den updates itself at night. If an update doesn't start properly, Den goes back to the version
before, by itself. When there's an update, Den shows it in **Settings**, **Advanced**,
**Server**, with an **Update now** button.

## Moving Den to another computer

1. Do [Step 2](#step-2-install-den) on the new computer, with the **same tunnel token**.
2. Open the link it shows and choose **Restore from a backup**.
3. Pick where the backup is: **A file on this device**, **On your NAS**, or **On this server**.
   Pick the backup (the newest is already chosen) and type your recovery words.
4. Turn off the old computer, or uninstall Den there: `sudo den uninstall`.

Everyone's phones find the family again on their own, because the address stays the same.

## If something goes wrong

**First, try this:** run the install line from Step 2 again. It's safe to run as many times as
you want. It fixes what it can and never deletes your family.

To see how Den is doing, type this in the terminal:

```sh
sudo den status
```

**"curl: command not found"** (or **"sudo: command not found"**). Your computer is missing a basic
tool. On Debian or Ubuntu, type `apt-get install -y curl sudo` and press Enter (as `root`), then try
again.

**"Den needs to be installed as the computer's administrator."** You left out `sudo`. Copy the
whole line from Step 2 again, including `| sudo sh` at the end.

**"This Raspberry Pi is running the 32-bit Raspberry Pi OS"**, or **"Den needs 64-bit"**. Den only
runs on 64-bit systems. Put the 64-bit system on the computer (for a Raspberry Pi, use Raspberry
Pi Imager and pick **Raspberry Pi OS (64-bit)**), then start again from Step 2.

**"This computer has ... memory"** or **"... free disk space"**. The computer is too small. Den
needs 1 GB of memory and 2 GB of free space. On a VPS, pick a bigger plan.

**"Couldn't reach download.docker.com"**, **"Couldn't download Den"** or **"Couldn't reach this
computer's software sources"**. The computer isn't getting to the internet. Check its connection,
wait a few minutes, and run the line again.

**"Something else on this computer already uses port 47733"**. Something else, often an older
Den, is in the way. If you set up an older Den by hand, stop it first, then run the line again.

**"This computer has Podman"**. Den needs Docker, and this computer has a look-alike. It's
simplest to use a fresh computer or VPS.

**"That doesn't look like a tunnel token"**. Copy the command from Cloudflare again (Step 1, number
5) and paste the whole thing. To give Den the token later: `sudo den tunnel`.

**The tunnel says it didn't connect.** Check the token: make a new one in Cloudflare if you're not
sure, then `sudo den tunnel` and paste it.

**Den's address shows a Cloudflare error page** (like "Bad gateway" or error 1033).
- Check Step 3: the Service URL must be exactly `http://hub:47733`.
- Run `sudo den status`. If it says Den isn't running, run the install line again.

**The setup link doesn't open.** It works only once. Make a new one: `sudo den setup-link`.

**The NAS can't be found.** Type its address as numbers (like `192.168.1.20`) instead of its name.
You'll find the address in your router's list of devices, or in the NAS's own settings. Den
needs to be on the same home network as the NAS, so a VPS can't back up to a NAS at home.

**Starting over.** `sudo den reset` deletes everything Den keeps on this computer and starts
fresh. The family's phones keep their own copy. It asks you to type `RESET` first.

**Removing Den.** `sudo den uninstall`.

Still stuck? Run `sudo den logs`, copy what it shows, and send it to whoever helps you with
computers.

## Optional extras

- **Sign in with Google.** Parents can also sign in to Den in a web browser with their Google
  account. In Den on your phone: **Settings**, **Advanced**, **Sign in with Google or Apple**. The
  screen walks you through it. Apple sign-in needs a paid Apple developer account, so most
  families skip it.
- **The AI helper**, which can add things from a photo of a flyer or a sentence like "soccer every
  Wednesday at 5 for Leo": **Settings**, **AI helper**. It's off until a parent turns it on.

## For the technical folks

How it works, other ways to run it and how to build it:
[docs/technical.md](docs/technical.md) and [docs/install-technical.md](docs/install-technical.md).

## License

AGPL-3.0 for the app, hub and relay; MIT for `den_core`.
