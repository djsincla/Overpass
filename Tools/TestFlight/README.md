# testflight

TestFlight for Overpass from the command line, through the App Store Connect API. It sets the test information, makes tester groups, waits for an uploaded build to finish processing, adds it to a group with its "what to test" text, submits it for Beta App Review, and invites testers. It signs its own tokens with CryptoKit, so there is nothing to install.

## The key

Make a team key in App Store Connect under Users and Access, Integrations, App Store Connect API, with the App Manager role. Apple lets you download the `.p8` file once. Then:

```
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
echo '{"keyID": "XXXXXXXXXX", "issuerID": "…"}' > ~/.appstoreconnect/testflight.json
```

The key ID and issuer ID aren't secret on their own; the `.p8` file is, and it stays out of this repository. `ASC_KEY_ID` and `ASC_ISSUER_ID` override the JSON file.

## Use

```
cd Tools/TestFlight
swift run testflight status
swift run testflight setup --description-file beta.txt --feedback-email AB6A@arrl.net \
    --contact-first Dwayne --contact-last Sinclair --contact-email AB6A@arrl.net \
    --contact-phone "+1 …" --notes-file review-notes.txt
swift run testflight group "Field testers" --public-link --link-limit 50
swift run testflight release 5 --group "Field testers" --whats-new "The 3D globe and map, offline."
swift run testflight invite someone@example.com --group "Field testers" --first Someone
```

## Watching a review

```
swift build -c release
.build/release/testflight watch --install            # every 2 hours
.build/release/testflight watch --install --every 1  # or every hour
.build/release/testflight watch --uninstall
```

`watch` compares each build's TestFlight state with the last run and posts a notification for any that changed, such as a build leaving Beta App Review. `--install` hands it to launchd as `com.dwaynesinclair.testflight-watch`, so it runs on its own schedule while you're logged in, with nothing else open. It saves the states in `~/.appstoreconnect/watch-<bundle id>.json` and logs to `~/Library/Logs/testflight-watch.log`. The agent runs the binary it was installed from, so install it from a release build and run it again after moving the folder.

`release` waits for Apple to finish processing the build (it checks every 30 s, for up to 45 minutes), so it can run straight after the upload. It only submits for review when the build is ready for it, and never for an internal group; `--no-submit` holds it back.

## A release, start to finish

1. Raise `CURRENT_PROJECT_VERSION` in `project.yml` and run `xcodegen`.
2. Archive and upload:

   ```
   xcodebuild archive -scheme Overpass -destination 'generic/platform=iOS' \
       -archivePath Overpass.xcarchive -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath Overpass.xcarchive \
       -exportOptionsPlist ExportOptions.plist -exportPath export -allowProvisioningUpdates
   ```

   with an `ExportOptions.plist` of `method` app-store-connect, `destination` upload, your team ID and automatic signing.
3. `swift run testflight release <build> --group "<group>" --whats-new "…"`.

Apple reviews the first build an external group sees, usually within a day. Later builds tend to go through quickly. Builds expire after 90 days.
