# Chrome Profile Tiler

Set up **Lightning Autofill** once, in one Chrome profile. Then use this tool to copy that set-up into as many new Chrome profiles as you like, and to open them all, tiled across your screens, with a random pause between each.

It exists so you don't have to repeat the Autofill instructions by hand in every profile, and so you can update every profile in one go if the rules change.

Works on **Windows** and **macOS**. You only need Google Chrome.

> Not affiliated with Google, or with the makers of Lightning Autofill.

---

## The big idea

```
   MASTER PROFILE            copy              PROFILES 1 to 12
   (you set this up    ------------------>     (made by the tool,
    by hand, once)                              identical copies)
```

- **The master profile** is one Chrome profile, just for setting up Lightning Autofill. You create it with the tool (menu step 2), then follow the Autofill instructions in it. You do this **once**.
- **The copies** are Profile 1, Profile 2 ... Profile 12 (or however many you choose). The tool creates them and copies the master's Lightning Autofill set-up into each one. Your master is never changed or launched along with them.
- **If the Autofill settings ever change,** update the master, then run the copy step again. Every profile gets the update.
- **When it's time,** the launch step opens all the copies, tiled across your screens, with a random pause between each. There's a quick test mode that uses a 1-second pause.

You never type anything about "extensions" or "profile names": the tool already knows it's Lightning Autofill and what the master profile is called.

---

## Install the tool

### Mac

**1. Open Terminal.** Press **Cmd + Space**, type **Terminal**, press **Enter**.

**2. Paste this line and press Enter:**

```
curl -fsSL https://raw.githubusercontent.com/willholley/chrome-profile-tiler/main/install.sh | bash
```

**3. Answer the prompts.** It downloads the tool into a `chrome-profile-tiler` folder in your home folder, offers to open `config.txt` so you can check the settings, then offers to start the menu.

**Next time**, start the menu with:

```
bash ~/chrome-profile-tiler/scripts/macos.sh
```

(Running the install line again updates the tool and keeps your `config.txt`.)

To change your settings later:

```
open -e ~/chrome-profile-tiler/config.txt
```

Because the files are downloaded by `curl` rather than a browser, macOS doesn't block them.

**Want to read the installer before running it?** This shows the script without running it (press **q** to leave):

```
curl -fsSL https://raw.githubusercontent.com/willholley/chrome-profile-tiler/main/install.sh | less
```

<details>
<summary><b>New to Terminal?</b></summary>

- **To run a command:** copy it, click in the Terminal window, press **Cmd + V** to paste, then press **Enter**.
- **Typing your password shows nothing.** When a command asks for a password, the screen stays blank as you type. That's normal. Type it and press Enter.
- **Nothing happens after you press Enter?** Some commands take a few seconds. When a new line appears ending in `%` or `$`, it has finished.
- **To stop a running script,** press **Control + C**.
- **The first time it moves windows,** macOS asks whether Terminal can control Google Chrome. Click **OK**.
</details>

<details>
<summary><b>Mac without the one-liner</b></summary>

Download the ZIP from GitHub (green **Code** button > **Download ZIP**) and unzip it. In Terminal type `cd ` (with a space after it), **drag the unzipped folder into the Terminal window**, press **Enter**, then paste these two lines one at a time:

```
xattr -dr com.apple.quarantine .
```

```
bash scripts/macos.sh
```

Edit `config.txt` with TextEdit first (right-click > Open With > TextEdit).
</details>

### Windows

1. On GitHub, click the green **Code** button, choose **Download ZIP**, and unzip it somewhere you'll remember (your Desktop is fine). To avoid a security warning, right-click the ZIP first, choose **Properties**, tick **Unblock**, then unzip.
2. Open **`config.txt`** in Notepad and check the settings (see [Settings](#settings)).
3. Double-click **`Start (Windows).bat`**.
4. If Windows says **"Windows protected your PC"**, click **More info**, then **Run anyway**.

---

## The menu

Both versions show the same menu. Type a number and press **Enter**.

```
1) One-time setup: let Chrome install Lightning Autofill for you
2) Open the master profile and set up Lightning Autofill
3) Copy the master profile to all the others
4) Launch all the profiles
5) Test launch (1-second pause instead of 45-75)
6) Check status
7) Remove the policy (also removes the extension)
8) Delete the profiles
Q) Quit
```

The first time, go through steps 1, 2, 3 in order. After that you'll mostly use 4.

---

## Walkthrough

### Step 1: One-time setup (menu option 1)

This lets Chrome install Lightning Autofill automatically in every profile, so you never have to visit the Web Store.

- **Windows:** you'll see a permission prompt (UAC). Click **Yes**.
- **Mac:** the tool creates a small settings profile and opens it. Open **System Settings**, search for **Profiles** (on some versions it's under **Privacy & Security > Profiles**, on others **General > Device Management**), double-click **Chrome Profile Tiler Policy**, click **Install**, and enter your Mac password. Then go back to Terminal and press **Enter**.

You only ever do this once. (To undo it, see [Undoing everything](#undoing-everything).)

### Step 2: Set up the master profile (menu option 2)

Chrome opens a brand-new profile. This is your **master profile**. Have your Autofill instructions open (you'll already have them from whoever organised the sale) and set up Lightning Autofill in this profile exactly as they say. Here's the same thing in short, with the differences for this tool pointed out.

1. **If Chrome asks you to sign in or turn on sync, choose "Don't sign in".** Signing in can make Chrome overwrite Lightning Autofill's settings with a cloud copy.
2. **Lightning Autofill installs itself.** It can take up to a minute to appear as a lightning icon at the top right. *Skip the "Install from the Chrome Web Store" step in the instructions: it's already done.* If the icon is hidden, click the jigsaw-piece icon and pin it.
3. **Open the extension's Options:** right-click the lightning icon and choose **Options**.
4. **Get a subscription, once.** The free version only allows 10 autofills a day per profile; the instructions recommend the Plus plan. Follow the instructions to subscribe. You'll be emailed an **Invoice Number**. You only need **one** subscription: the same key works in every profile. If you already have one, skip this.
5. **Activate your key.** In Options, go to the **Settings** tab. Under **Subscription**, paste **only the part of the Invoice Number before the hyphen** (for `9D3C9801-0001`, paste `9D3C9801`) and click **Activate**. You should see **✓ Activated** and **Plan: Plus**.
6. **Set Import mode to Replace.** Go to the **Sync** tab and, in the Import/Export section, tick **Replace**.
7. **Import the rules.** Still on the **Sync** tab, scroll to **Remote Import**, paste the rules URL from the instructions, and click the **Import** button directly under it.
8. **Check the rules.** On the **Form Fields** tab, check that the rules look the way the instructions say they should.
9. **Click Save** at the bottom of the Form Fields tab. **Don't skip this, and don't switch tabs first**: unsaved changes are lost.
10. **Close Chrome completely.** On a Mac press **Cmd + Q**; on Windows close every Chrome window.

> **You do not repeat this in other profiles.** The instructions say to do it for every profile; this tool replaces that with step 3.

### Step 3: Copy the master to all the profiles (menu option 3)

Choose option 3. The tool:

1. checks the master has Lightning Autofill set up (and warns you if it looks empty, which usually means Save wasn't clicked);
2. creates Profile 1 ... Profile 12 if they don't exist yet, and lets Chrome install the extension in each;
3. copies the master's Lightning Autofill data into every one: your activation key, the rules, and the options;
4. backs up whatever was in the copies first.

Chrome is closed for this step (it asks first). Creating twelve new profiles takes a few minutes.

**What is *not* copied:** Chrome's own settings, such as whether the lightning icon is pinned to the toolbar. You don't need it pinned. To autofill, right-click the page > **Autofill** > **Execute profile**. To open Options in a copy, go to `chrome://extensions`, click **Details** on Lightning Autofill, then **Extension options**.

### Step 4: Check that the copies work (menu option 5)

Choose **5) Test launch**. It opens every profile with a **1-second** pause instead of the normal 45-75 seconds, so you can check quickly. Look at two or three of the windows:

- Lightning Autofill > **Options > Settings** shows **✓ Activated** and **Plan: Plus**.
- **Form Fields** shows the same rules as the master.
- Optionally, open the test page from the instructions and try right-click > **Autofill** > **Execute profile**.

If a copy isn't activated or is missing rules, see [If the copy didn't work](#if-the-copy-didnt-work).

Close Chrome when you're done.

### Step 5: Launch for real (menu option 4)

Choose **4) Launch all the profiles**. It opens Profile 1 to Profile 12 one at a time, each on the page from your settings, with a random 45-75 second pause between them, and arranges the windows in a grid across all your screens. On a Mac it also keeps the computer awake until it finishes.

### Later: the Autofill settings changed

1. Menu option **2** to open the master.
2. Do the changes there. If the rules changed, that's usually steps 7 to 9 again: **Remote Import > Import**, check, then **Save**. (Keep Import mode on **Replace**.)
3. Close Chrome completely.
4. Menu option **3** to copy the master to every profile again.
5. Optionally, option **5** to check.

Nothing else needs repeating.

---

## Settings

Everything lives in `config.txt`. Open it in Notepad (Windows) or TextEdit (Mac). Write values exactly as shown, with no quotes.

| Setting | What it does |
|---|---|
| `STARTUP_URL` | The page every profile opens on when you launch them |
| `PROFILE_COUNT` | How many profiles to make and launch (Profile 1 to Profile N) |
| `DELAY_MIN` / `DELAY_MAX` | The random pause, in seconds, between launching one profile and the next |

There's nothing to set for the extension or the master profile. The tool always uses Lightning Autofill, and the master is always the profile it creates for you. A few optional advanced settings are at the bottom of `config.txt`, commented out.

**For manual testing,** you don't need to edit `DELAY_MIN` and `DELAY_MAX`. Use menu option **5**, which always uses a 1-second pause.

---

## If the copy didn't work

First, run **6) Check status**. After step 3, every copy should show roughly the same "saved settings" size as the master (a freshly installed extension is much smaller). Then:

- **A copy isn't activated.** Open Lightning Autofill's Options in that profile, go to **Settings**, paste the first part of your Invoice Number and click **Activate**. One subscription key works in every profile.
- **A copy is missing the rules.** In that profile's Options, go to **Sync**, set Import mode to **Replace**, paste the rules URL under **Remote Import**, click **Import**, then click **Save** on the Form Fields tab.
- **Several copies are wrong.** Check that you clicked **Save** in the master and closed Chrome completely before step 3, then run step 3 again. Also check that none of the copies is signed in to a Google account with Chrome sync on, because Chrome can overwrite the copied data from the cloud.
- **The extension didn't install in the copies.** Open `chrome://policy` in Chrome and look for Lightning Autofill. If it's missing, the one-time setup (step 1) wasn't completed. On a Mac that means the settings profile hasn't been approved yet.
- **Still stuck.** Repeat the instructions by hand in that profile. The tool never stops you doing that.

---

## If your computer warns you

These warnings appear because the files came from the internet and aren't signed. You can read every script in the `scripts/` folder (and `install.sh`) before running anything.

- **Windows, "Windows protected your PC":** click **More info**, then **Run anyway**.
- **Mac, "cannot be opened because Apple cannot check it"** (only if you downloaded a ZIP and double-clicked the `.command` file): use the one-line install above instead, or "Mac without the one-liner". On macOS 15 and later you can also go to System Settings > Privacy & Security and click **Open Anyway**.
- **Mac, "permission denied":** run `chmod +x "Start (Mac).command" scripts/macos.sh` in Terminal from the project folder, or start it with `bash scripts/macos.sh`, which doesn't need the permission.
- **Mac, asks about controlling Chrome:** click **OK**. This is how the windows get positioned (System Settings > Privacy & Security > Automation).

---

## What it does to your computer

Being upfront, because some of this is unusual:

- **The Mac installer downloads this project from GitHub** into `~/chrome-profile-tiler`. That's the only network request the scripts make themselves; Chrome itself downloads the extension.
- **It sets a Chrome policy** (registry on Windows, a settings profile on Mac) that force-installs Lightning Autofill and, optionally, sets the startup page. This applies to **every Chrome profile on that computer**, not just the ones this tool makes. Chrome will show "Managed by your organization", and the extension can't be removed by hand while the policy is in place. Removing the policy later removes the extension too (see [Undoing everything](#undoing-everything)).
- **It copies the extension's saved data** between profile folders inside Chrome's data directory. This isn't an official Chrome feature, so it can fail in some situations (see above). What was there before is backed up to a `generated/` folder inside this project.
- **It closes Chrome** (after asking) for the steps that need it. Save your work first.
- **Your normal Chrome profile (`Default`) is never touched** by any step.

---

## Limitations

- **Profile names and pictures are manual.** Chrome has no supported way to script them. In each profile: click the profile icon, then **Customize profile**. It's worth naming the master profile so you can tell its window apart.
- **Windows don't line up exactly.** On Windows, change `$Pad` at the top of `scripts/windows.ps1` (7 is typical). On a Mac, Chrome has a minimum window width, so with many windows on a small screen they'll overlap slightly; lower `PROFILE_COUNT` or use a bigger screen. Screens with different display scaling may be slightly off.
- **It only manages Lightning Autofill,** installed from the Chrome Web Store.

---

## Undoing everything

There are two separate clean-ups, and they do different things.

**Option 7: remove the policy.** This removes the "Managed by your organization" label and gives you back control of the startup page. **It also removes Lightning Autofill from every profile**, together with its saved settings, the next time Chrome starts. That's how Chrome treats an extension that was installed by a policy: when the policy goes, the extension goes. So don't use this just to tidy up while you still want the extension. The menu warns you and asks before doing it.

**Option 8: delete the profiles.** This deletes Profile 1 to Profile N and removes them from Chrome's profile list. It will:

- show you exactly which profiles it's about to delete, and ask you to **type `DELETE`** to continue;
- ask separately about the master profile (the default answer is to keep it, so you can copy it again later);
- **never touch your `Default` profile**;
- move the folders to the **Trash / Recycle Bin** instead of erasing them, so you can get them back until you empty it (Windows may delete a very large profile permanently if it doesn't fit in the Recycle Bin);
- keep a backup of Chrome's `Local State` file in `generated/`, and put it back if the clean-up fails.

Deleting a profile removes everything in it: history, bookmarks, saved passwords, cookies and any accounts signed in there. If Chrome still lists a deleted profile in its profile picker afterwards, click the three dots on that card and choose **Delete**.

**To remove everything,** run option 8 first and then option 7. On a Mac you can then also delete the `~/chrome-profile-tiler` folder.

---

## How it works (for the curious)

| Step | Windows | macOS |
|---|---|---|
| Install the tool | Download the ZIP | `install.sh` downloads the ZIP with `curl` into `~/chrome-profile-tiler` |
| Install the extension everywhere | Registry keys under `HKLM\SOFTWARE\Policies\Google\Chrome` | A `.mobileconfig` settings profile for `com.google.Chrome` |
| Create profiles | `chrome --profile-directory="Profile N"` creates the profile, and the policy installs the extension | The same, through `open -na "Google Chrome"` |
| Copy the master | Copies `Local Extension Settings\<id>` and `Sync Extension Settings\<id>` from the master's folder into each profile | Same |
| Tile windows | Win32 `SetWindowPos` on each new Chrome window | AppleScript `set bounds` on each new Chrome window |
| Multiple screens | Windows are split evenly across screens; each screen gets its own grid | Same |

The master profile lives in a Chrome profile folder called `Autofill Master`, next to Chrome's own `Default` and `Profile N` folders.

Files:

```
install.sh              macOS one-line installer (curl | bash)
Start (Windows).bat     double-click launcher for Windows
Start (Mac).command     double-click launcher for macOS (the installer is more reliable)
config.txt              the only file most people need to edit
scripts/windows.ps1     Windows implementation (PowerShell 5.1+)
scripts/macos.sh        macOS implementation (bash 3.2+, the version macOS ships)
generated/              created at run time: backups and the Mac settings profile (git-ignored)
```

## Contributing

Issues and pull requests welcome. Keep the scripts ASCII-only (Windows PowerShell 5.1 misreads non-ASCII characters in files without a byte-order mark) and compatible with bash 3.2. In `install.sh`, keep all code inside functions with `main "$@"` as the last line, and read prompts from `/dev/tty`, because the script arrives on stdin when piped.

## Licence

MIT. See `LICENSE`. Put your own name in the copyright line.
