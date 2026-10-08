//! Explicit launch composition; build features and saved metadata never select a vault.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum AuthorityMode {
    #[default]
    Unavailable,
    Fixture,
    Native,
}

impl AuthorityMode {
    pub fn is_fixture(self) -> bool {
        self == Self::Fixture
    }
    pub fn editable(self) -> bool {
        self != Self::Unavailable
    }
    /// Pure validation runs before profile/fixture files, stdin, or vault access.
    pub fn for_launch(
        native: bool,
        fixture: bool,
        legacy_profile: bool,
        credential_stdin: bool,
        attachment_fixture: bool,
    ) -> Result<Self, &'static str> {
        if native {
            if fixture || legacy_profile || credential_stdin || attachment_fixture {
                return Err(
                    "--native-authority cannot be combined with synthetic fixtures, --profile or --credential-stdin",
                );
            }
            if !cfg!(feature = "native-authority") {
                return Err(
                    "--native-authority requires the nondefault native-authority build feature",
                );
            }
            if !cfg!(target_os = "macos") {
                return Err("Native authority is available only on macOS");
            }
            Ok(Self::Native)
        } else if fixture {
            Ok(Self::Fixture)
        } else {
            Ok(Self::Unavailable)
        }
    }
    pub fn loaded_notice(self) -> &'static str {
        match self {
            Self::Fixture => "Loaded fixture connections. Nothing was sent.",
            Self::Native => {
                "Loaded connections from the separate Rust Keychain vault. Nothing was sent."
            }
            Self::Unavailable => "Connection storage is unavailable. Nothing was sent.",
        }
    }
    pub fn saved_notice(self) -> &'static str {
        match self {
            Self::Fixture => "Saved to the in-memory fixture vault. Nothing was sent.",
            Self::Native => "Saved to the separate Rust Keychain vault. Nothing was sent.",
            Self::Unavailable => "Connection storage is unavailable. Nothing was sent.",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::AuthorityMode;

    #[test]
    fn features_never_select_authority_and_native_conflicts_are_rejected_first() {
        assert_eq!(
            AuthorityMode::for_launch(false, false, false, false, false),
            Ok(AuthorityMode::Unavailable)
        );
        assert_eq!(
            AuthorityMode::for_launch(false, true, false, false, false),
            Ok(AuthorityMode::Fixture)
        );
        for options in [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
        ] {
            assert!(
                AuthorityMode::for_launch(true, options.0, options.1, options.2, options.3)
                    .unwrap_err()
                    .contains("cannot be combined")
            );
        }
        let native = AuthorityMode::for_launch(true, false, false, false, false);
        if cfg!(all(feature = "native-authority", target_os = "macos")) {
            assert_eq!(native, Ok(AuthorityMode::Native));
        } else {
            assert!(native.is_err());
        }
    }
}
