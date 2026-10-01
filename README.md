# Chrome Profile Tiler

Set up a bunch of Chrome profiles the same way, then open them all at once, tiled across your screens.

It can:

1. **Create profiles** (Profile 1 ... Profile N) and **install a Chrome extension** in each one.
2. **Copy the extension's settings** from one "primary" profile to all the others.
3. **Launch every profile** with a random pause between each, open on a page you choose, with the windows arranged in a grid across **all your screens**.

Works on **Windows** and **macOS**. No installs needed beyond Google Chrome.

> Not affiliated with Google, or with the makers of any extension you use it with.

---

## Quick start: Mac

You need Terminal for this, but you only have to paste one line.

**1. Open Terminal.** Press **Cmd + Space**, type **Terminal**, press **Enter**.

**2. Paste this line and press Enter:**

```
curl -fsSL https://raw.githubusercontent.com/willholley/chrome-profile-tiler/main/install.sh | bash
```

**3. Answer the prompts.** The installer downloads the project into a `chrome-profile-tiler` folder in your home folder, offers to open `config.txt` so you can check the settings, then offers to start the menu. Say yes to both the first time, then follow [Using the menu](#using-the-menu).

**Next time**, run the same line again. It updates to the latest version, **keeps your `config.txt`**, and offers to start the menu. Or skip the update and go straight to the menu:

```
bash ~/chrome-profile-tiler/scripts/macos.sh
```

To edit your settings later:

```
open -e ~/chrome-profile-tiler/config.txt
```

Because the files are downloaded by `curl` rather than a browser, macOS doesn't block them, so there's no "unidentified developer" warning to get past.

**Want to read the installer before running it?** Paste this instead. It shows the script without running it (press **q** to leave):

```
curl -fsSL https://raw.githubusercontent.com/willholley/chrome-profile-tiler/main/install.sh | less
```

### New to Terminal?

- **To run a command:** copy it, click in the Terminal window, press **Cmd + V** to paste, then press **Enter**.
- **Typing your password shows nothing.** When a command asks for a password, the screen stays blank as you type. That's normal. Type it and press Enter.
- **Nothing happens after you press Enter?** Some commands take a few seconds. When a new line appears ending in `%` or `$`, it has finished.
- **To stop a running script,** press **Control + C**.
- **The first time it moves windows,** macOS asks whether Terminal can control Google Chrome. Click **OK**.

### Mac without the one-liner

If you'd rather not run an installer from the internet, download the ZIP from GitHub (green **Code** button > **Download ZIP**) and unzip it. In Terminal type `cd ` (with a space after it), **drag the unzipped folder into the Terminal window**, press **Enter**, then paste these two lines one at a time:

```
xattr -dr com.apple.quarantine .
```

```
bash scripts/macos.sh
```

Edit `config.txt` with TextEdit first (right-click > Open With > TextEdit).

---

## Quick start: Windows

1. On GitHub, click the green **Code** button, choose **Download ZIP**, and unzip it somewhere you'll remember (your Desktop is fine). To avoid a security warning, right-click the ZIP first, choose **Properties**, tick **Unblock**, then unzip.
2. Open **`config.txt`** in Notepad and check the settings (see [Settings](#settings-configtxt)).
3. Double-click **`Start (Windows).bat`**.
4. If Windows says **"Windows protected your PC"**, click **More info**, then **Run anyway**.
5. Follow [Using the menu](#using-the-menu).

---

## Settings (`config.txt`)

The important lines:

| Setting | What it does |
|---|---|
| `EXTENSION_ID` | The extension to install (the long ID at the end of its Chrome Web Store URL) |
| `STARTUP_URL` | The page to open in every profile |
| `PROFILE_COUNT` | How many profiles (Profile 1 to Profile N) |
| `SOURCE_PROFILE` | Your "primary" profile, where the extension is already configured |

Every setting has a comment explaining it. Write values exactly as shown, with no quotes. Open it in Notepad (Windows) or TextEdit (Mac).

## Using the menu

Both versions show the same menu:

```
1) First-time setup (install policy, create profiles, install extension)
2) Open primary profile (to configure the extension)
3) Copy primary settings to the other profiles
4) Launch all profiles, tiled across your screens
5) Check status
6) Remove the policy (undo step 1)
Q) Quit
```

Type a number and press **Enter**. The first time, go in order:

1. **Option 1.** Installs Chrome's policy, then opens each profile once so the extension installs. Windows shows a permission prompt (UAC). On a Mac you'll approve a settings profile in System Settings; the script walks you through it.
2. **Option 2.** Opens your primary profile. Configure the extension there the way you want it, then **close Chrome completely**.
3. **Option 3.** Copies those settings to the other profiles. It lists exactly which profiles will be overwritten and asks first; whatever was there is backed up.
4. **Option 4.** Launches everything, tiled. This is the only step you'll repeat day to day.

Use **Option 5** any time to see which profiles have the extension and how much saved data each has. A configured profile usually shows a much bigger number than a fresh one, which is a quick way to find your primary.

---

## If your computer warns you

These warnings appear because the files came from the internet and aren't signed. You can read every script in the `scripts/` folder (and `install.sh`) before running anything.

- **Windows, "Windows protected your PC":** click **More info**, then **Run anyway**.
- **Mac, "cannot be opened because Apple cannot check it"** (only if you downloaded a ZIP and double-clicked the `.command` file): use the one-line install above instead, or the "Mac without the one-liner" steps. On macOS 15 and later you can also go to System Settings > Privacy & Security and click **Open Anyway**.
- **Mac, "permission denied":** run `chmod +x "Start (Mac).command" scripts/macos.sh` in Terminal from the project folder, or start it with `bash scripts/macos.sh`, which doesn't need the permission.
- **Mac, asks about controlling Chrome:** click **OK**. This is how the windows get positioned (System Settings > Privacy & Security > Automation).

---

## What it does to your computer

Being upfront, because some of this is unusual:

- **The Mac installer downloads this project from GitHub** into `~/chrome-profile-tiler`. That's the only network request the scripts make themselves; Chrome itself downloads the extension.
- **It sets a Chrome policy** (registry on Windows, a settings profile on Mac) that force-installs the extension and, optionally, sets the startup page. This applies to **every Chrome profile on that computer**, not just yours in the config. Chrome will show "Managed by your organization", and the extension can't be removed from Chrome until you undo the policy (menu option 6).
- **It copies the extension's saved data** between profile folders inside Chrome's data directory. This isn't an official Chrome feature, so it can fail for some extensions or situations (see below). Existing data is backed up to a `generated/` folder inside this project before being overwritten.
- **It closes Chrome** (after asking) for the steps that need it. Save your work first.

---

## Limitations and troubleshooting

**Profile names and pictures are manual.** Chrome has no supported way to script them. In each profile: click the profile icon, then **Customize profile**.

**Copied settings didn't show up.** Some possible reasons:

- *The profile is signed in to a Google account with Chrome sync on.* Chrome can overwrite the copied "sync" storage from the cloud. Try it on a profile that isn't signed in, or use the extension's own Export/Import feature (if it has one) instead.
- *Your primary profile wasn't the configured one.* Run option 5 and check which profile has the most saved data, then set `SOURCE_PROFILE`.
- *The extension keeps its data somewhere else,* such as an online account, a paid licence tied to a login, or a database the script doesn't copy. Check the extension's own settings for an export/import or cloud-sync option.
- *Chrome was still running* during the copy. Option 3 closes it for you, but check the Task Manager (Windows) or Activity Monitor (Mac) if in doubt.

**The extension didn't install in some profiles.** Open `chrome://policy` in Chrome and check the extension appears. On a Mac this means the settings profile from option 1 hasn't been approved yet. Then run option 1 again.

**Windows don't line up exactly.** On Windows, change `$Pad` at the top of `scripts/windows.ps1` (7 is typical). On a Mac, Chrome has a minimum window width, so if you have many windows on a small screen they'll overlap slightly; lower `PROFILE_COUNT` or use a bigger screen.

**Windows with different display scaling** (for example a laptop screen at 150% next to a monitor at 100%) may come out slightly off on one screen.

**It only works with Chrome from the Web Store** for the force-install step.

**Undoing everything:** run option 6 to remove the policy, then delete the profiles from Chrome if you no longer want them (profile icon > Settings > delete). On a Mac you can also delete the `~/chrome-profile-tiler` folder.

---

## How it works (for the curious)

| Step | Windows | macOS |
|---|---|---|
| Install | Download the ZIP | `install.sh` downloads the ZIP with `curl` into `~/chrome-profile-tiler` |
| Force-install extension, set startup page | Registry keys under `HKLM\SOFTWARE\Policies\Google\Chrome` | A `.mobileconfig` settings profile for `com.google.Chrome` |
| Create profiles | Launches `chrome --profile-directory="Profile N"`, which creates the profile | Same, through `open -na "Google Chrome"` |
| Copy settings | Copies `Local Extension Settings\<id>` and `Sync Extension Settings\<id>` between profile folders | Same |
| Tile windows | Win32 `SetWindowPos` on each new Chrome window | AppleScript `set bounds` on each new Chrome window |
| Multiple screens | Windows are split evenly across screens; each screen gets its own grid | Same |

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
