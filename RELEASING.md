# Releasing

```sh
SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=… ./release.sh
```

`release.sh` tests, builds, signs, notarizes and staples, then writes `dist/appcast-<version>/appcast.xml` signed with the Sparkle key stored in the login keychain under the account `dimmer`. It prints the `gh release create` command that publishes the zip and the appcast. Installed copies read the appcast from the latest GitHub release.
