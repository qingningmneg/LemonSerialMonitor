using System.Runtime.Versioning;

namespace CommMonitor.Service.Security;

[SupportedOSPlatform("windows")]
internal sealed class InstallSecurityOptions
{
    public const string SectionName = "InstallSecurity";

    public const string KeyRingFileName = "lemon-ai-key-ring.v1.json";

    public required string CoreRootMetadataPath { get; init; }

    public required string AuthorizedUserSid { get; init; }

    public string? AuthorizedClientImagePath { get; init; }

    public string? AuthorizedClientSha256 { get; init; }

    public string KeyRingPath => Path.Combine(
        Path.GetFullPath(CoreRootMetadataPath),
        KeyRingFileName);

    public void Validate()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(CoreRootMetadataPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(AuthorizedUserSid);
        _ = new System.Security.Principal.SecurityIdentifier(AuthorizedUserSid);

        bool hasImagePath = !string.IsNullOrWhiteSpace(AuthorizedClientImagePath);
        bool hasHash = !string.IsNullOrWhiteSpace(AuthorizedClientSha256);
        if (hasImagePath != hasHash)
        {
            throw new InvalidOperationException(
                "The authorized AI client image path and SHA-256 must be configured together.");
        }

        if (hasImagePath)
        {
            _ = Path.GetFullPath(AuthorizedClientImagePath!);
            if (AuthorizedClientSha256!.Length != 64 ||
                AuthorizedClientSha256.Any(static character =>
                    character is not (>= '0' and <= '9') and
                    not (>= 'a' and <= 'f')))
            {
                throw new InvalidOperationException(
                    "The authorized AI client SHA-256 must be 64 lowercase hexadecimal characters.");
            }
        }
    }
}
