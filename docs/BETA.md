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

1. Download `Tacet-<version>-beta.dmg` and open it.
2. Drag **Tacet** onto **Applications**.
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

Hidden apps show as "off" in System Settings › Menu Bar. Quitting Tacet turns
them all back on; quit Tacet before deleting it.

## Send feedback

Right-click Tacet's arrow › **Send Feedback…**. It adds the Tacet and macOS
versions, nothing else.

## Update to a new beta

Quit Tacet (right-click › Quit Tacet), download the new DMG and drag Tacet
onto Applications, replacing the old one. Every beta is signed with the same
certificate, so your access grant and settings carry over. A new download
needs **Open Anyway** (or the `xattr` command) once again.

---

## For the developer: making and publishing a beta

**Once:** create the signing certificate and keep its backup safe.

```bash
scripts/make-beta-cert.sh
```

It creates the self-signed "Tacet Beta" code-signing identity in the login
keychain and saves a `.p12` backup in `~/Documents`; its password is in
Keychain Access as "Tacet Beta signing backup".
All betas must use this identity: macOS ties the file grant to it.

**Each beta:**

1. Bump `CFBundleShortVersionString` in `Support/Info.plist`.
2. Build the DMG (options: `EXPIRES_DAYS`, `FEEDBACK_URL`, `SITE_URL`):

   ```bash
   FEEDBACK_URL="https://gettacet.com/feedback" scripts/make-beta-dmg.sh
   ```

3. Publish it on GitHub Releases in the public, binaries-only repo
   [jvzaniolo/tacet-beta](https://github.com/jvzaniolo/tacet-beta) (its
   README is the tester guide; feedback goes to its issues):

   ```bash
   gh release create v0.1.0-beta.1 build/Tacet-0.1.0-beta.dmg \
     --repo jvzaniolo/tacet-beta --prerelease \
     --title "Tacet 0.1.0 beta 1" --notes "What changed…"
   ```

   Testers get `https://github.com/jvzaniolo/tacet-beta/releases`
   (`/releases/latest` skips prereleases). First release: v0.1.0-beta.1,
   2026-10-16, expires 2026-12-15.

To test the "beta has ended" window: `BETA=1 EXPIRES_DAYS=0 scripts/build-app.sh`.

### Updates: manual for now (Sparkle later)

Sparkle 2 would work with a stable self-signed certificate in principle: it
checks updates with its own EdDSA signature and requires the new build to
match the running app's code-signing identity, which the shared "Tacet Beta"
certificate provides; the update it installs isn't quarantined. It is not
included yet: it adds a third-party framework that must be embedded and
signed by the build script, an EdDSA key to guard, and an appcast to host.
For a short beta, testers download the new DMG. Revisit Sparkle together
with the Developer ID (notarized) release.
