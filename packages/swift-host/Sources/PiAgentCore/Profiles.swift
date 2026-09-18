import Foundation

/// LiteLLM credentials are delivered by the native vault owner over private IPC.
/// This is deliberately not an import/migration path for Pi credential files.
public enum ProfileFiles {
    public static func discover(path: String) throws -> JSON {
        throw AgentError("profiles_retired", "Configure LiteLLM in the native Keychain settings. Pi models/auth files are not an active configuration authority.")
    }
    public static func credentials(profile: Profile, supplied: String?) throws -> (Profile, String) {
        guard profile.provider == "litellm", profile.raw["source"].isNull,
              profile.raw["apiKeyEnv"].isNull, profile.raw["authHeader"].isNull else {
            throw AgentError("vault_configuration_required", "Only explicit LiteLLM configuration from the native vault is accepted. File, shell and environment credentials are unsupported.")
        }
        guard let key = supplied, !key.isEmpty, key.utf8.count <= 16384,
              !key.utf8.contains(13), !key.utf8.contains(10), !key.utf8.contains(0) else {
            throw AgentError("credential_unavailable", "Save a valid LiteLLM API key in the native configuration vault.")
        }
        return (profile, key)
    }
}
