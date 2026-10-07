//! Explicit debug-only GUI fixture admission. No production capability inference,
//! native authority, credential discovery, automatic trust or provider send occurs.
use bello_agent_core::{
    Profile,
    project_authority::{
        ProjectAuthority,
        connections::{ConnectionDraft, SYNTHETIC_KEY},
    },
};
use std::{fs::OpenOptions, io::Read, path::Path};

const MAX_PROFILE_BYTES: u64 = 256 * 1024;

pub(crate) struct AttachmentFixture {
    profile: Profile,
}
impl AttachmentFixture {
    pub(crate) fn read(
        path: &Path,
        synthetic_connections: bool,
        key: Option<&str>,
    ) -> Result<Self, String> {
        if !synthetic_connections {
            return Err(
                "--synthetic-attachment-fixture requires explicit --synthetic-connections".into(),
            );
        }
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC);
        }
        let file = options
            .open(path)
            .map_err(|_| "Could not read the synthetic attachment profile")?;
        if !file
            .metadata()
            .map_err(|_| "Could not inspect the synthetic attachment profile")?
            .is_file()
        {
            return Err("Synthetic attachment profile must be a regular file".into());
        }
        let mut bytes = Vec::new();
        file.take(MAX_PROFILE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Could not read the synthetic attachment profile")?;
        if bytes.len() as u64 > MAX_PROFILE_BYTES {
            return Err("Synthetic attachment profile exceeds 256 KiB".into());
        }
        Self::parse(&bytes, synthetic_connections, key)
    }
    fn parse(bytes: &[u8], synthetic_connections: bool, key: Option<&str>) -> Result<Self, String> {
        if !synthetic_connections {
            return Err(
                "--synthetic-attachment-fixture requires explicit --synthetic-connections".into(),
            );
        }
        if key.is_some_and(|key| key != SYNTHETIC_KEY) {
            return Err("Synthetic attachment fixture requires its fixed fake credential".into());
        }
        // Never echo malformed JSON or user-supplied header/key values in errors.
        let profile: Profile = serde_json::from_slice(bytes)
            .map_err(|_| "Invalid synthetic attachment profile JSON")?;
        profile
            .validate()
            .map_err(|_| "Invalid synthetic attachment profile")?;
        let endpoint = profile
            .endpoint()
            .map_err(|_| "Invalid synthetic attachment fixture endpoint")?;
        let numeric_loopback = endpoint
            .host_str()
            .and_then(|host| {
                host.trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .ok()
            })
            .is_some_and(|ip| ip.is_loopback());
        if !numeric_loopback || uuid::Uuid::parse_str(&profile.id).is_err() {
            return Err("Synthetic attachment fixture requires a UUID connection ID and numeric loopback endpoint".into());
        }
        if !profile.input.iter().any(|kind| kind == "text") || !profile.supports_images() {
            return Err(
                "Synthetic attachment fixture requires explicit text and image inputs".into(),
            );
        }
        if !profile.headers.is_empty() {
            return Err("Synthetic attachment fixture does not accept custom headers".into());
        }
        Ok(Self { profile })
    }
    pub(crate) fn seed(self, authority: &ProjectAuthority) -> Result<(), String> {
        let mut draft = ConnectionDraft::new(self.profile, "Synthetic attachment fixture".into());
        draft.key_input = SYNTHETIC_KEY.into();
        let result = authority
            .load_connections()
            .and_then(|loaded| authority.save_connection(&loaded, &draft));
        use zeroize::Zeroize;
        draft.key_input.zeroize();
        result
            .map(|_| ())
            .map_err(|_| "Could not save the synthetic attachment fixture connection".into())
    }
}

#[cfg(test)]
mod tests {
    use super::AttachmentFixture;
    use bello_agent_core::project_authority::{ProjectAuthority, connections::SYNTHETIC_KEY};
    fn profile() -> serde_json::Value {
        serde_json::json!({
            "id":"fe7655ec-97f3-40d7-a481-a87cd08be12d", "api":"openai-responses", "providerId":"litellm",
            "modelId":"fixture-model", "baseUrl":"http://127.0.0.1:9", "contextWindow":32000, "maxOutputTokens":4096,
            "input":["text","image"]
        })
    }
    fn parse(
        value: serde_json::Value,
        enabled: bool,
        key: Option<&str>,
    ) -> Result<AttachmentFixture, String> {
        AttachmentFixture::parse(&serde_json::to_vec(&value).unwrap(), enabled, key)
    }
    #[test]
    fn admitted_fixture_uses_normal_saved_connection_without_trusting_project() {
        let fixture = parse(profile(), true, None).unwrap();
        let (authority, _) = ProjectAuthority::with_synthetic_bytes(None).unwrap();
        fixture.seed(&authority).unwrap();
        let saved = authority.load_connections().unwrap();
        assert_eq!(saved.profiles().len(), 1);
        assert!(saved.profiles()[0].profile.supports_images());
        assert!(saved.profiles()[0].available);
    }
    #[test]
    fn fixture_requires_explicit_flag_and_fixed_stdin_key() {
        assert!(parse(profile(), false, None).is_err());
        assert!(parse(profile(), true, Some("not-a-fixture-key")).is_err());
        assert!(parse(profile(), true, Some(SYNTHETIC_KEY)).is_ok());
    }
    #[test]
    fn missing_capability_malformed_identity_headers_and_nonloopback_are_rejected() {
        for input in [
            serde_json::Value::Null,
            serde_json::json!(["text"]),
            serde_json::json!(["image"]),
        ] {
            let mut value = profile();
            if input.is_null() {
                value.as_object_mut().unwrap().remove("input");
            } else {
                value["input"] = input;
            }
            assert!(parse(value, true, None).is_err());
        }
        for endpoint in [
            "http://localhost:9",
            "https://example.com",
            "http://192.168.1.1:9",
            "http://127.0.0.1:9?api_key=private",
        ] {
            let mut value = profile();
            value["baseUrl"] = endpoint.into();
            let error = parse(value, true, None).err().unwrap();
            assert!(!error.contains("private"));
        }
        let mut value = profile();
        value["headers"] = serde_json::json!({"x-custom":"private"});
        assert!(parse(value, true, None).is_err());
        let mut value = profile();
        value["id"] = "not-a-uuid".into();
        assert!(parse(value, true, None).is_err());
        assert!(AttachmentFixture::parse(b"bad-json", true, None).is_err());
    }
}
