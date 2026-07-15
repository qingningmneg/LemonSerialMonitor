using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using CommMonitor.Core.Ai;
using CommMonitor.Service.Security;
using CommMonitor.Service.Sessions;

namespace CommMonitor.Service.Tests.Sessions;

[SupportedOSPlatform("windows")]
public sealed class CursorProtectorTests
{
    private const string SessionId = "s1.test-session";
    private const string FilterHash = "sha256:filter-a";

    [Fact]
    public void Cursor_round_trips_and_rejects_tampering_or_binding_mismatch()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        var protector = new CursorProtector(sandbox.CreateKeyRing());
        DateTimeOffset now = DateTimeOffset.UtcNow;

        SignedCursor cursor = protector.ProtectCursor(
            SessionId,
            FilterHash,
            scannedSequence: 42,
            now);

        Assert.Equal(
            42,
            protector.UnprotectCursor(cursor.Value, SessionId, FilterHash, now).Sequence);
        Assert.Equal(
            AiErrorCodes.InvalidCursor,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectCursor(cursor.Value + "A", SessionId, FilterHash, now)).Code);
        Assert.Equal(
            AiErrorCodes.InvalidCursor,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectCursor(cursor.Value, "s1.other-session", FilterHash, now)).Code);
        Assert.Equal(
            AiErrorCodes.CursorFilterMismatch,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectCursor(cursor.Value, SessionId, "sha256:filter-b", now)).Code);
    }

    [Fact]
    public void Tampered_expiry_is_not_trusted_before_hmac_verification()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        var protector = new CursorProtector(sandbox.CreateKeyRing());
        SignedCursor cursor = protector.ProtectCursor(SessionId, FilterHash, 42, now);
        string[] components = cursor.Value.Split('.');
        JsonObject payload = JsonNode.Parse(DecodeBase64Url(components[1]))!.AsObject();
        payload["issuedAtUtcTicks"] = now.AddDays(-8).UtcDateTime.Ticks;
        payload["expiresAtUtcTicks"] = now.AddDays(-1).UtcDateTime.Ticks;
        components[1] = EncodeBase64Url(JsonSerializer.SerializeToUtf8Bytes(payload));
        string tampered = string.Join('.', components);

        AiCursorException exception = Assert.Throws<AiCursorException>(() =>
            protector.UnprotectCursor(tampered, SessionId, FilterHash, now));

        Assert.Equal(AiErrorCodes.InvalidCursor, exception.Code);
    }

    [Fact]
    public void Cursor_expires_at_seven_days_and_receipt_expires_at_ninety_days()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        var protector = new CursorProtector(sandbox.CreateKeyRing());
        DateTimeOffset now = DateTimeOffset.UtcNow;
        SignedCursor cursor = protector.ProtectCursor(SessionId, FilterHash, 7, now);
        SignedResumeReceipt receipt = protector.ProtectResumeReceipt(
            SessionId,
            FilterHash,
            7,
            now);

        Assert.Equal(
            7,
            protector.UnprotectCursor(
                cursor.Value,
                SessionId,
                FilterHash,
                now.AddDays(7).AddTicks(-1)).Sequence);
        Assert.Equal(
            AiErrorCodes.CursorExpired,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectCursor(
                    cursor.Value,
                    SessionId,
                    FilterHash,
                    now.AddDays(7))).Code);
        Assert.Equal(
            7,
            protector.UnprotectResumeReceipt(
                receipt.Value,
                SessionId,
                FilterHash,
                now.AddDays(90).AddTicks(-1)).Sequence);
        Assert.Equal(
            AiErrorCodes.CursorExpired,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectResumeReceipt(
                    receipt.Value,
                    SessionId,
                    FilterHash,
                    now.AddDays(90))).Code);
    }

    [Fact]
    public async Task Protected_key_survives_restart_without_plaintext()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        ProtectedKeyRing firstRing = sandbox.CreateKeyRing();
        ProtectedKeyMaterial active = await firstRing.GetActiveKeyAsync();
        var firstProtector = new CursorProtector(firstRing);
        SignedCursor cursor = firstProtector.ProtectCursor(SessionId, FilterHash, 91, now);
        string persistedJson = await File.ReadAllTextAsync(sandbox.Options.KeyRingPath);

        using JsonDocument document = JsonDocument.Parse(persistedJson);
        Assert.Equal(1, document.RootElement.GetProperty("version").GetInt32());
        Assert.DoesNotContain(
            Convert.ToBase64String(active.KeyBytes.ToArray()),
            persistedJson,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            Convert.ToHexString(active.KeyBytes.Span),
            persistedJson,
            StringComparison.OrdinalIgnoreCase);

        ProtectedKeyRing restartedRing = sandbox.CreateKeyRing();
        ProtectedKeyMaterial restartedActive = await restartedRing.GetActiveKeyAsync();
        var restartedProtector = new CursorProtector(restartedRing);
        Assert.Equal(active.KeyId, restartedActive.KeyId);
        Assert.Equal(
            91,
            restartedProtector.UnprotectCursor(
                cursor.Value,
                SessionId,
                FilterHash,
                now.AddMinutes(1)).Sequence);
    }

    [Fact]
    public void Default_security_policy_is_system_administrators_only()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        AssertStrictSecurity(
            WindowsKeyRingFileSecurityPolicy.CreateProtectedFileSecurity());
        AssertStrictSecurity(
            WindowsKeyRingFileSecurityPolicy.CreateProtectedDirectorySecurity());
    }

    [Fact]
    public async Task Default_security_policy_fails_closed_for_an_untrusted_owner()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        SecurityIdentifier currentUser = WindowsIdentity.GetCurrent().User!;
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, domainSid: null);
        var administrators = new SecurityIdentifier(
            WellKnownSidType.BuiltinAdministratorsSid,
            domainSid: null);
        if (currentUser.Equals(system) || currentUser.Equals(administrators))
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        SecurityIdentifier initialOwner = Assert.IsType<SecurityIdentifier>(
            new DirectoryInfo(sandbox.Root)
                .GetAccessControl(AccessControlSections.Owner)
                .GetOwner(typeof(SecurityIdentifier)));
        Assert.True(
            initialOwner.Equals(currentUser) || initialOwner.Equals(administrators),
            $"Unexpected temporary-root owner: {initialOwner.Value}");
        var strictRing = new ProtectedKeyRing(sandbox.Options);

        await Assert.ThrowsAsync<IOException>(async () =>
            await strictRing.GetActiveKeyAsync());
    }

    [Fact]
    public async Task Directory_security_persistence_failure_is_reported_as_io_failure()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        var original = new InvalidOperationException("directory security persistence failed");
        var policy = new ThrowingTestFileSecurityPolicy(
            directoryException: original,
            fileException: null);
        var ring = new ProtectedKeyRing(sandbox.Options, policy);

        IOException failure = await Assert.ThrowsAsync<IOException>(async () =>
            await ring.GetActiveKeyAsync());

        Assert.Same(original, failure.InnerException);
        Assert.Equal(1, policy.DirectoryCalls);
        Assert.Equal(0, policy.FileCalls);
    }

    [Fact]
    public async Task Key_file_security_persistence_failure_is_reported_as_io_failure()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        var original = new InvalidOperationException("key-file security persistence failed");
        var policy = new ThrowingTestFileSecurityPolicy(
            directoryException: null,
            fileException: original);
        var ring = new ProtectedKeyRing(sandbox.Options, policy);

        IOException failure = await Assert.ThrowsAsync<IOException>(async () =>
            await ring.GetActiveKeyAsync());

        Assert.Same(original, failure.InnerException);
        Assert.Equal(2, policy.DirectoryCalls);
        Assert.Equal(1, policy.FileCalls);
    }

    [Fact]
    public async Task Rotation_retains_every_unexpired_retired_key_across_restart()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        var protector = new CursorProtector(ring);
        SignedResumeReceipt first = protector.ProtectResumeReceipt(
            SessionId,
            FilterHash,
            10,
            now);

        await ring.RotateAsync(now.AddMinutes(1));
        SignedResumeReceipt second = protector.ProtectResumeReceipt(
            SessionId,
            FilterHash,
            20,
            now.AddMinutes(1));
        await ring.RotateAsync(now.AddMinutes(2));
        SignedResumeReceipt third = protector.ProtectResumeReceipt(
            SessionId,
            FilterHash,
            30,
            now.AddMinutes(2));

        var restartedProtector = new CursorProtector(sandbox.CreateKeyRing());
        DateTimeOffset validationTime = now.AddMinutes(3);
        Assert.Equal(10, restartedProtector.UnprotectResumeReceipt(
            first.Value, SessionId, FilterHash, validationTime).Sequence);
        Assert.Equal(20, restartedProtector.UnprotectResumeReceipt(
            second.Value, SessionId, FilterHash, validationTime).Sequence);
        Assert.Equal(30, restartedProtector.UnprotectResumeReceipt(
            third.Value, SessionId, FilterHash, validationTime).Sequence);

        using JsonDocument document = JsonDocument.Parse(
            await File.ReadAllTextAsync(sandbox.Options.KeyRingPath));
        Assert.Equal(3, document.RootElement.GetProperty("keys").GetArrayLength());
    }

    [Fact]
    public async Task Rotation_prunes_every_retired_key_after_its_retention_horizon()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        ProtectedKeyMaterial first = await ring.GetActiveKeyAsync();
        _ = new CursorProtector(ring).ProtectResumeReceipt(
            SessionId,
            FilterHash,
            10,
            now);
        ProtectedKeyMaterial second = await ring.RotateAsync(now.AddMinutes(1));
        _ = new CursorProtector(ring).ProtectResumeReceipt(
            SessionId,
            FilterHash,
            20,
            now.AddMinutes(1));
        _ = await ring.RotateAsync(now.AddMinutes(2));

        _ = await ring.RotateAsync(now.AddDays(91));

        using JsonDocument document = JsonDocument.Parse(
            await File.ReadAllTextAsync(sandbox.Options.KeyRingPath));
        string[] remainingIds = document.RootElement
            .GetProperty("keys")
            .EnumerateArray()
            .Select(element => element.GetProperty("keyId").GetString()!)
            .ToArray();
        Assert.DoesNotContain(first.KeyId, remainingIds);
        Assert.DoesNotContain(second.KeyId, remainingIds);
        Assert.Equal(2, remainingIds.Length);
    }

    [Fact]
    public async Task Protected_key_ring_rejects_a_hard_link_without_mutating_the_target()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        _ = await ring.GetActiveKeyAsync();
        string outsidePath = Path.Combine(sandbox.Root, "outside-key-ring.json");
        File.Copy(sandbox.Options.KeyRingPath, outsidePath);
        byte[] original = await File.ReadAllBytesAsync(outsidePath);
        File.Delete(sandbox.Options.KeyRingPath);
        CreateHardLink(sandbox.Options.KeyRingPath, outsidePath);
        ProtectedKeyRing restarted = sandbox.CreateKeyRing();

        await Assert.ThrowsAsync<IOException>(async () =>
            await restarted.GetActiveKeyAsync());

        Assert.Equal(original, await File.ReadAllBytesAsync(outsidePath));
    }

    [Fact]
    public async Task Emergency_retirement_returns_key_retired_and_activates_a_new_key()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        var protector = new CursorProtector(ring);
        ProtectedKeyMaterial compromised = await ring.GetActiveKeyAsync();
        SignedCursor compromisedCursor = protector.ProtectCursor(
            SessionId,
            FilterHash,
            12,
            now);

        await ring.EmergencyRetireAsync(compromised.KeyId, now.AddMinutes(1));

        Assert.Equal(
            AiErrorCodes.CursorKeyRetired,
            Assert.Throws<AiCursorException>(() =>
                protector.UnprotectCursor(
                    compromisedCursor.Value,
                    SessionId,
                    FilterHash,
                    now.AddMinutes(2))).Code);
        ProtectedKeyMaterial replacement = await ring.GetActiveKeyAsync();
        Assert.NotEqual(compromised.KeyId, replacement.KeyId);
        SignedCursor replacementCursor = protector.ProtectCursor(
            SessionId,
            FilterHash,
            13,
            now.AddMinutes(2));
        Assert.Equal(13, protector.UnprotectCursor(
            replacementCursor.Value,
            SessionId,
            FilterHash,
            now.AddMinutes(3)).Sequence);
    }

    [Fact]
    public async Task Rotation_prunes_an_emergency_tombstone_after_the_receipt_horizon()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        ProtectedKeyMaterial compromised = await ring.GetActiveKeyAsync();
        _ = new CursorProtector(ring).ProtectResumeReceipt(
            SessionId,
            FilterHash,
            12,
            now);
        await ring.EmergencyRetireAsync(compromised.KeyId, now.AddMinutes(1));

        _ = await ring.RotateAsync(now.AddDays(91));

        using JsonDocument document = JsonDocument.Parse(
            await File.ReadAllTextAsync(sandbox.Options.KeyRingPath));
        string[] remainingIds = document.RootElement
            .GetProperty("keys")
            .EnumerateArray()
            .Select(element => element.GetProperty("keyId").GetString()!)
            .ToArray();
        Assert.DoesNotContain(compromised.KeyId, remainingIds);
        Assert.Equal(2, remainingIds.Length);
    }

    [Fact]
    public void Missing_key_material_returns_key_unavailable_for_an_unexpired_cursor()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        var protector = new CursorProtector(sandbox.CreateKeyRing());
        SignedCursor cursor = protector.ProtectCursor(SessionId, FilterHash, 14, now);
        File.Delete(sandbox.Options.KeyRingPath);
        var restarted = new CursorProtector(sandbox.CreateKeyRing());

        Assert.Equal(
            AiErrorCodes.CursorKeyUnavailable,
            Assert.Throws<AiCursorException>(() =>
                restarted.UnprotectCursor(
                    cursor.Value,
                    SessionId,
                    FilterHash,
                    now.AddMinutes(1))).Code);
    }

    [Fact]
    public void Expired_cursor_can_resume_only_with_a_valid_receipt()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        var protector = new CursorProtector(sandbox.CreateKeyRing());
        SignedCursor cursor = protector.ProtectCursor(SessionId, FilterHash, 42, now);
        SignedResumeReceipt receipt = protector.ProtectResumeReceipt(
            SessionId,
            FilterHash,
            42,
            now);

        CursorResolution resumed = protector.ResolvePosition(
            SessionId,
            FilterHash,
            cursor.Value,
            receipt.Value,
            afterSequence: null,
            allowUnverifiedSeek: false,
            now.AddDays(8));

        Assert.Equal(42, resumed.Sequence);
        Assert.True(resumed.ContinuityProven);
        Assert.Empty(resumed.Warnings);
        Assert.Equal(
            AiErrorCodes.CursorExpired,
            Assert.Throws<AiCursorException>(() => protector.ResolvePosition(
                SessionId,
                FilterHash,
                cursor.Value,
                resumeReceipt: null,
                afterSequence: null,
                allowUnverifiedSeek: false,
                now.AddDays(8))).Code);
    }

    [Fact]
    public void Arbitrary_seek_requires_opt_in_and_returns_continuity_unproven()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new KeyRingSandbox();
        DateTimeOffset now = DateTimeOffset.UtcNow;
        var protector = new CursorProtector(sandbox.CreateKeyRing());

        Assert.Equal(
            AiErrorCodes.ContinuityUnproven,
            Assert.Throws<AiCursorException>(() => protector.ResolvePosition(
                SessionId,
                FilterHash,
                cursor: null,
                resumeReceipt: null,
                afterSequence: 42,
                allowUnverifiedSeek: false,
                now)).Code);

        CursorResolution resolution = protector.ResolvePosition(
            SessionId,
            FilterHash,
            cursor: null,
            resumeReceipt: null,
            afterSequence: 42,
            allowUnverifiedSeek: true,
            now);

        Assert.Equal(42, resolution.Sequence);
        Assert.False(resolution.ContinuityProven);
        Assert.Equal([AiErrorCodes.ContinuityUnproven], resolution.Warnings);
    }

    private static byte[] DecodeBase64Url(string value)
    {
        string base64 = value.Replace('-', '+').Replace('_', '/');
        base64 = base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '=');
        return Convert.FromBase64String(base64);
    }

    private static string EncodeBase64Url(ReadOnlySpan<byte> value) =>
        Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static void AssertStrictSecurity(FileSystemSecurity security)
    {
        var trusted = new HashSet<SecurityIdentifier>
        {
            new(WellKnownSidType.LocalSystemSid, domainSid: null),
            new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null),
        };
        Assert.True(security.AreAccessRulesProtected);
        SecurityIdentifier owner = Assert.IsType<SecurityIdentifier>(
            security.GetOwner(typeof(SecurityIdentifier)));
        Assert.Contains(owner, trusted);
        FileSystemAccessRule[] rules = security
            .GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        Assert.Equal(2, rules.Length);
        Assert.All(rules, rule =>
        {
            Assert.Equal(AccessControlType.Allow, rule.AccessControlType);
            Assert.Contains((SecurityIdentifier)rule.IdentityReference, trusted);
            Assert.Equal(
                FileSystemRights.FullControl,
                rule.FileSystemRights & FileSystemRights.FullControl);
        });
        Assert.All(trusted, identity => Assert.Contains(
            rules,
            rule => identity.Equals(rule.IdentityReference)));
    }

    private static void CreateHardLink(string linkPath, string existingPath)
    {
        if (!CreateHardLinkW(linkPath, existingPath, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(
        string fileName,
        string existingFileName,
        IntPtr securityAttributes);

    private sealed class KeyRingSandbox : IDisposable
    {
        public KeyRingSandbox()
        {
            Root = Path.Combine(
                Path.GetTempPath(),
                $"lemon-key-ring-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Root);
            Options = new InstallSecurityOptions
            {
                CoreRootMetadataPath = Root,
                AuthorizedUserSid = WindowsIdentity.GetCurrent().User!.Value,
            };
        }

        public string Root { get; }

        public InstallSecurityOptions Options { get; }

        public ProtectedKeyRing CreateKeyRing() =>
            new(Options, new PermissiveTestFileSecurityPolicy());

        public void Dispose()
        {
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, recursive: true);
            }
        }
    }

    private sealed class PermissiveTestFileSecurityPolicy : IKeyRingFileSecurityPolicy
    {
        public void ProtectMetadataDirectory(string path)
        {
        }

        public void ProtectKeyRingFile(string path)
        {
        }
    }

    private sealed class ThrowingTestFileSecurityPolicy(
        Exception? directoryException,
        Exception? fileException) : IKeyRingFileSecurityPolicy
    {
        public int DirectoryCalls { get; private set; }

        public int FileCalls { get; private set; }

        public void ProtectMetadataDirectory(string path)
        {
            DirectoryCalls++;
            if (directoryException is not null)
            {
                throw directoryException;
            }
        }

        public void ProtectKeyRingFile(string path)
        {
            FileCalls++;
            if (fileException is not null)
            {
                throw fileException;
            }
        }
    }
}
