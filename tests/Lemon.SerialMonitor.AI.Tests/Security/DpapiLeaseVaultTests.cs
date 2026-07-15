using System.Text;
using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Security;

namespace Lemon.SerialMonitor.AI.Tests.Security;

public sealed class DpapiLeaseVaultTests
{
    [Fact]
    public async Task Round_trip_is_atomic_and_disk_envelope_contains_no_plaintext_secret()
    {
        string root = Path.Combine(Path.GetTempPath(), "Lemon-AiVaultTests", Guid.NewGuid().ToString("N"));
        string path = Path.Combine(root, "leases.json");
        Directory.CreateDirectory(root);
        try
        {
            using var vault = new DpapiLeaseVault(path, new ReversingProtector());
            var pending = new PreparedCaptureDto(
                "reservation-1",
                "lease-1",
                "top-secret-value",
                "client-1",
                "7",
                DateTimeOffset.UtcNow.AddMinutes(1).ToString("O"));

            await vault.WritePendingAsync(pending);

            StoredLease lease = Assert.Single(await vault.ReadAllAsync());
            Assert.Equal(LeaseVaultState.Pending, lease.State);
            Assert.Equal(pending.LeaseSecret, lease.LeaseSecret);
            string disk = await File.ReadAllTextAsync(path);
            Assert.DoesNotContain(pending.LeaseSecret, disk, StringComparison.Ordinal);
            Assert.DoesNotContain(pending.LeaseId, disk, StringComparison.Ordinal);
            Assert.Empty(Directory.EnumerateFiles(root, "*.tmp"));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Activate_rotates_secret_and_remove_clears_the_record()
    {
        string root = Path.Combine(Path.GetTempPath(), "Lemon-AiVaultTests", Guid.NewGuid().ToString("N"));
        string path = Path.Combine(root, "leases.json");
        Directory.CreateDirectory(root);
        try
        {
            using var vault = new DpapiLeaseVault(path, new ReversingProtector());
            await vault.WritePendingAsync(new PreparedCaptureDto(
                "reservation-1", "lease-1", "secret-old", "client-1", "1",
                DateTimeOffset.UtcNow.AddMinutes(1).ToString("O")));
            await vault.ActivateAsync(
                new ActiveCaptureDto(
                    "lease-1", "secret-new", "client-1", "2", "session-1", "running"),
                "reservation-1");

            StoredLease active = Assert.Single(await vault.ReadAllAsync());
            Assert.Equal(LeaseVaultState.Active, active.State);
            Assert.Equal("secret-new", active.LeaseSecret);
            Assert.Equal("session-1", active.SessionId);

            await vault.RemoveAsync("lease-1");
            Assert.Empty(await vault.ReadAllAsync());
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task Corrupt_ciphertext_fails_closed()
    {
        string root = Path.Combine(Path.GetTempPath(), "Lemon-AiVaultTests", Guid.NewGuid().ToString("N"));
        string path = Path.Combine(root, "leases.json");
        Directory.CreateDirectory(root);
        try
        {
            await File.WriteAllTextAsync(path, "{\"schemaVersion\":1,\"protection\":\"x\",\"ciphertextBase64\":\"AA==\"}");
            using var vault = new DpapiLeaseVault(path, new ReversingProtector());

            await Assert.ThrowsAsync<InvalidDataException>(() => vault.ReadAllAsync());
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class ReversingProtector : ILeaseDataProtector
    {
        public byte[] Protect(ReadOnlySpan<byte> plaintext)
        {
            byte[] bytes = plaintext.ToArray();
            Array.Reverse(bytes);
            return bytes.Select(static value => (byte)(value ^ 0xA5)).ToArray();
        }

        public byte[] Unprotect(ReadOnlySpan<byte> ciphertext)
        {
            byte[] bytes = ciphertext.ToArray().Select(static value => (byte)(value ^ 0xA5)).ToArray();
            Array.Reverse(bytes);
            return bytes;
        }
    }
}
