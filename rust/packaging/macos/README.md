# Separate Rust application identity

These approved repository templates define the Rust bundle and its isolated
project-authority namespace. They do not build, sign, install or register an app,
access a certificate, create a Keychain item, or import the Swift vault.

The bundle template deliberately leaves version/build substitution to a future
reviewed packaging step. The identity record restricts the backend to the
existing source Developer ID team and separate Rust bundle identifier. Having
this record does not establish that a signing certificate/private key is
available on a Mac or that the running binary satisfies the requirement.

The optional core native-authority feature compiles the adapter only. The app's
production constructor remains unavailable until a separately reviewed host
composition and native acceptance gate. Actual signing, Keychain operations,
locked/denied interaction behavior and user-desktop validation require their own
explicit authorization. Do not add an unsigned, plaintext, source-vault or
credential fallback. No release or main-branch publication is part of this work.
