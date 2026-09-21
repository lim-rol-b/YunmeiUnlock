# Privacy

YunmeiUnlock does not operate a developer-owned backend and does not collect analytics.

## Data processing

- The account and password entered by the user are used only to authenticate with the Yunmei service.
- The password is not persisted by the app.
- Session tokens are retained only in memory while retrieving the user's schools and locks.
- Retrieved lock configuration, including the Bluetooth UUIDs and lock secret, is stored in the device Keychain.
- The cached Bluetooth peripheral identifier is stored in local app preferences.
- Removing the lock configuration from the app deletes the saved Keychain configuration.

No account, token, lock secret, signing certificate, or provisioning profile is included in this source repository or its release artifacts.

This is an unofficial client. Users should review the service provider's own privacy terms before signing in.
