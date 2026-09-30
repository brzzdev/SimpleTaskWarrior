# The app updates itself with Sparkle, from GitHub releases

The Release build updates in place through Sparkle 2. This is the app's first explicit network feature, and a second way to install it besides downloading the DMG. There's one channel. The feed is `https://github.com/brzzdev/SimpleTaskWarrior/releases/latest/download/appcast.xml`, which GitHub redirects to the `appcast.xml` attached to the release marked latest. `just publish` generates that appcast from the notarised zip it uploads, so no Pages site or committed appcast is needed. It holds only its own release, which is enough while there's one platform and one channel. The release is published as a draft and marked latest only once the zip, DMG and appcast are all attached, so the feed never points at a release with missing assets.

Sparkle checks each update archive's EdDSA signature against the `SUPublicEDKey` in the Info.plist. The private key lives in the publisher's login keychain, where Sparkle's `generate_keys` put it and `generate_appcast` reads it. It's backed up in 1Password, as the "SimpleTaskWarrior Sparkle EdDSA private key" document in the Dev vault. That's the file `generate_keys -x` exports, which `generate_keys -f` imports onto another Mac.

## Consequences

- A Debug build never starts the updater, so it never checks the production feed or installs the Release product over itself. Its **Check for Updates…** stays disabled.
- Sparkle orders releases by `CFBundleVersion`, the commit count `just archive` stamps, and `just publish` refuses a release that isn't numbered above every earlier one.
- Sparkle comes in through SwiftPM, and `just publish` runs the `generate_appcast` from the pinned package, not from a global install. The Developer ID export re-signs Sparkle's nested helpers under the hardened runtime. Outside the App Sandbox, Sparkle doesn't use its installer XPC services, so they ship unused.
- The appcast has no deltas. With a single release in the appcast, there's no older build to diff against.
- If the private key is lost, Sparkle still accepts an update that changes the EdDSA key or the app's code signing identity, but not both at once. It checks the code signature against the installed app's designated requirement, which pins the Developer ID team. To recover, publish a release that carries a new `SUPublicEDKey` from `generate_keys`, with its archive signed by the new key and the app signed by the same team. A release that changes both strands every installed copy, and each one then has to be reinstalled from the DMG by hand.

## Considered options

- **An appcast on GitHub Pages or committed to the repo.** Either would keep a history of releases, but it's a second place to publish, and it can drift from the release assets. The redirect to the latest release needs neither.
- **No in-app updates.** Every update would mean downloading and replacing the app by hand, and nothing would tell users that a new release exists.
