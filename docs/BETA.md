# Tacet beta

*Português: [BETA.pt-BR.md](BETA.pt-BR.md)*

Thanks for testing Tacet! It hides the menu bar apps you choose behind one
arrow, using macOS's own "Allow in the Menu Bar" switches.

## Requirements

- macOS 27 or later.
- The beta expires 60 days after it was built (the date is shown in Tacet's
  right-click menu). When it ends, Tacet stops hiding and turns everything
  back on.

## Install

1. Download `Tacet-<version>-beta.<n>.zip` from your Gumroad link. Safari
   unzips it into a folder with Tacet and a "How to Install" guide (otherwise
   double-click the zip).
2. Drag **Tacet** into **Applications**.
3. Open Tacet from Applications. The first time, macOS blocks it because the
   beta isn't notarized by Apple. To allow it:
   - Open **System Settings › Privacy & Security**, scroll down to the
     message about Tacet and click **Open Anyway**, then confirm; or
   - in Terminal: `xattr -dr com.apple.quarantine /Applications/Tacet.app`,
     then open Tacet again.
4. Tacet asks for one thing: access to the file where macOS keeps the menu
   bar switches. Click **Grant Access…**, select
   `group.com.apple.controlcenter.plist` in the folder Tacet opens, and click
   **Grant Access**.
5. Turn on the apps you want hidden under **Hide in Tacet**. Hold ⌘ and drag
   Tacet's arrow to the right of them once.

Click the arrow, or press **⇧⌘<** from any app, to show or hide them. In
Settings (right-click the arrow › **Settings…**) you can change or remove
that shortcut and turn on **Open at Login**. Shown apps hide again by
themselves a few seconds after the pointer leaves the menu bar (never while a
menu is open).

Hidden apps show as "off" in System Settings › Menu Bar. Quitting Tacet turns
them all back on; quit Tacet before deleting it.

## Send feedback

Right-click Tacet's arrow › **Send Feedback…**. It adds the Tacet and macOS
versions, nothing else.

## Update to a new beta

Quit Tacet (right-click › Quit Tacet), download the new zip and drag Tacet
into Applications, replacing the old one. Every beta is signed with the same
certificate, so your access grant and settings carry over. A new download
needs **Open Anyway** (or the `xattr` command) once again.

---

## For the developer: making and publishing a beta

**Once:** create the signing certificate and keep its backup safe.

```bash
scripts/make-beta-cert.sh
```

It creates the self-signed "Tacet Beta" code-signing identity in the login
keychain and saves a `.p12` backup in
`~/Library/Application Support/Tacet/signing/` (not `~/Documents`, which may
sync to iCloud Drive); its password is in Keychain Access as "Tacet Beta
signing backup". Copy the `.p12` to offline storage.
All betas must use this identity: macOS ties the file grant to it.

**Each beta:**

1. Keep `CFBundleShortVersionString` in `Support/Info.plist` (e.g. 0.1.0)
   and raise `BETA_NUMBER` (the menu then shows "Beta 2 (0.1.0) · ends …").
2. Build the zip (options: `EXPIRES_DAYS`, default 60; `FEEDBACK_URL`;
   `SITE_URL`):

   ```bash
   BETA_NUMBER=2 FEEDBACK_URL="mailto:jv.zaniolo@gmail.com" scripts/make-beta-zip.sh
   ```

   It writes `build/Tacet-<version>-beta.<n>.zip` with Tacet.app and
   `How to Install.txt` (from `Support/`, with the expiry date filled in).
   A zip, not a DMG: an unnotarized DMG makes macOS warn twice (the DMG,
   then the app); a zip warns only for the app. `scripts/make-beta-dmg.sh`
   stays for the notarized release.
   `FROM_DMG=<dmg> scripts/make-beta-zip.sh` repacks an already released
   DMG's app without rebuilding it. With a `mailto:`
   feedback link, "Send Feedback…" opens a message whose subject carries the
   Tacet and macOS versions, nothing else.
3. Upload the zip to the Gumroad product (a $0 product; each tester gets
   their own download link and can reply to the Gumroad email). The
   `jvzaniolo/tacet-beta` GitHub repo hosted beta 1 and is being made
   private; don't publish betas there.

Releases so far:

| Beta | Date | Expires | SHA-256 |
| --- | --- | --- | --- |
| 1 (0.1.0) | 2026-10-16 | 2026-12-15 | `f8e99a6b…df132` (GitHub release, now retired) |
| 2 (0.1.0) | 2026-10-16 | 2026-12-15 | `dd7e3b4996e856006dd9f1b45a615aa9ec3400c2a88e4b0051bdd8f0d0bcb313` (build 202610162022; replaces build 202610162010, `9e7ac46e…6aadc`, whose "Visit Website" pointed at gettacet.com, a domain that isn't ours) |
| 2 (0.1.0), zip | 2026-10-17 | 2026-12-15 | `2186bfe0cb5fc9648c0beceff31868edd06cf323845e4947893fae1cc6b6442e` (same app as the beta 2 DMG, repacked with `FROM_DMG`; replaces the DMG on Gumroad) |

To test the "beta has ended" window: `BETA=1 EXPIRES_DAYS=0 scripts/install.sh`.

### Updates: manual for now (Sparkle later)

Sparkle 2 would work with a stable self-signed certificate in principle: it
checks updates with its own EdDSA signature and requires the new build to
match the running app's code-signing identity, which the shared "Tacet Beta"
certificate provides; the update it installs isn't quarantined. It is not
included yet: it adds a third-party framework that must be embedded and
signed by the build script, an EdDSA key to guard, and an appcast to host.
For a short beta, testers download the new zip. Revisit Sparkle together
with the Developer ID (notarized) release.
