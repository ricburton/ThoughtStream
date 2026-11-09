# ThoughtStream beta releases

The direct beta uses Developer ID signing, Apple notarization and Sparkle 2.10.1.
Public artifacts and the signed update feed live in `ricburton/thoughtstream-releases`;
application source is published separately at `ricburton/ThoughtStream`. Private keys and credentials stay in the local Keychain.

## One-time setup

1. Use the Apple Developer Account Holder's account to create a **Developer ID
   Application** certificate. Install it with its matching private key in the
   login Keychain. `security find-identity -v -p codesigning` must list it.
2. Configure a notarization credential profile without putting passwords in chat,
   shell arguments, source files or release artifacts. Run this interactively:

   ```sh
   xcrun notarytool store-credentials ThoughtStream-Notary
   ```

   Follow its prompts using the Apple account, developer team ID and an
   app-specific password. Creating the app-specific password is a user step.
   App Store Connect API credentials are another supported option.
3. The Sparkle EdDSA private key is in the login Keychain under account
   `ThoughtStream`; `SUPublicEDKey` contains only its public key. Preserve a secure
   backup of that Keychain. Never commit or upload the private key.
4. Sign `appcast.xml` with the matching key. The app requires signed feeds and
   signed archives before extraction. The feed has a `beta` channel.

## Cut a release

Increment `CFBundleVersion` for every release and update
`CFBundleShortVersionString` for user-visible versions. Existing released build
numbers and archives must not be reused or replaced.

```sh
python3 Scripts/Release-Beta.py --publish
```

The command takes a private source snapshot, assembles the app, signs nested code
inside out with Developer ID and Hardened Runtime, checks bundled tools, submits
to Apple, staples the ticket, and verifies Gatekeeper acceptance. It then creates
an app-only ZIP, signs the beta feed and archive, uploads a draft release, downloads
it to verify its checksum, publishes the release and commits the feed last. It
never installs or launches ThoughtStream. It retains source manifests, logs,
artifacts and notarization receipts for diagnosis.

To prepare while account setup is pending:

```sh
python3 Scripts/Release-Beta.py --prepare-only --work-dir /absolute/private/release-directory
# Later, resume that exact snapshot:
python3 Scripts/Release-Beta.py --work-dir /absolute/private/release-directory --publish
```

`--identity` selects a specific Developer ID identity if multiple are installed.
`--notary-profile` selects a different saved notarization profile. The GitHub CLI
must be authenticated with write access to the release repository. The existing
feed is updated using its expected GitHub content SHA to reject concurrent edits.

Do not label a prepared or ad-hoc-signed app as notarized. A failed submission
publishes nothing. If publication fails after the release becomes visible but
before feed publication, retain its logs and finish that feed update rather than
creating another release using the same build number.

## Update behavior and verification

The app checks every four hours and has a Check for Updates menu command.
Installation always requires a user choice. An update restart is deferred while
a session has an active turn or queue worker. There is no launchd installer,
forced update or automatic development restart. Keep `restarts-paused` in place.

The current release checks prove compilation, tool execution, signing,
notarization, archive/feed signatures and uploaded-byte integrity. They do not
launch the main app or prove the interactive update flow. When the user authorizes
an app launch, verify a real old-to-new update on a separate test profile,
including an active chat, persisted history and failed-download recovery.
