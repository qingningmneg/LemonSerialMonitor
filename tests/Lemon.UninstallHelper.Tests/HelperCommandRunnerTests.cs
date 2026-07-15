using System.Globalization;
using System.Security.Cryptography;
using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Completion;
using Lemon.UninstallHelper.Execution;
using Lemon.UninstallHelper.Manifest;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Tests;

public sealed class HelperCommandRunnerTests
{
    private static readonly Guid InstallId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly DateTimeOffset CreatedUtc =
        DateTimeOffset.ParseExact(
            "2026-07-14T03:04:05.0000000Z",
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    [Theory]
    [InlineData(DeletionStatus.Completed, DeletionStatus.Completed, HelperExitCodes.Completed, "Completed")]
    [InlineData(DeletionStatus.Completed, DeletionStatus.PendingReboot, HelperExitCodes.RebootRequired, "PendingReboot")]
    [InlineData(DeletionStatus.PendingReboot, DeletionStatus.Failed, HelperExitCodes.Failed, "Failed")]
    public void Aggregates_every_root_and_writes_one_authenticated_completion(
        DeletionStatus first,
        DeletionStatus second,
        int expectedExitCode,
        string expectedStatus)
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var boundary = new FakeBoundary(CreateWorkBytes(key));
        var deleter = new FakeDeleter(first, second);
        var runner = new HelperCommandRunner(
            boundary,
            deleter,
            new FixedTimeProvider(CreatedUtc));

        int exitCode = runner.Run(Command());

        Assert.Equal(expectedExitCode, exitCode);
        Assert.Equal(2, deleter.Seen.Count);
        Assert.Equal([ApprovedRootRole.AppRoot, ApprovedRootRole.AiStateRoot],
            deleter.Seen.Select(root => root.Role));
        Assert.Equal(1, boundary.WriteCount);
        CompletionPayload result = CompletionTokenCodec.ParseAndValidate(
            Assert.IsType<byte[]>(boundary.Result),
            InstallId,
            new string('a', 64),
            key);
        Assert.Equal(expectedStatus, result.Status);
        Assert.Equal("2026-07-14T03:04:05.0000000Z", result.CreatedUtc);
    }

    [Fact]
    public void Refuses_a_work_manifest_bound_to_another_install_before_deletion()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var boundary = new FakeBoundary(CreateWorkBytes(key));
        var deleter = new FakeDeleter(DeletionStatus.Completed);
        var runner = new HelperCommandRunner(
            boundary,
            deleter,
            new FixedTimeProvider(CreatedUtc));
        HelperCommand command = Command() with
        {
            InstallId = Guid.Parse("22222222-2222-2222-2222-222222222222"),
        };

        Assert.Throws<CryptographicException>(() => runner.Run(command));

        Assert.Empty(deleter.Seen);
        Assert.Equal(0, boundary.WriteCount);
    }

    [Fact]
    public void Refuses_tampered_work_bytes_before_deletion()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        byte[] bytes = CreateWorkBytes(key);
        bytes[bytes.Length / 2] ^= 1;
        var boundary = new FakeBoundary(bytes);
        var deleter = new FakeDeleter(DeletionStatus.Completed);
        var runner = new HelperCommandRunner(
            boundary,
            deleter,
            new FixedTimeProvider(CreatedUtc));

        Assert.ThrowsAny<Exception>(() => runner.Run(Command()));

        Assert.Empty(deleter.Seen);
        Assert.Equal(0, boundary.WriteCount);
    }

    [Fact]
    public void Converts_a_root_engine_exception_to_failed_but_continues_other_roots()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var boundary = new FakeBoundary(CreateWorkBytes(key));
        var deleter = new ThrowThenCompleteDeleter();
        var runner = new HelperCommandRunner(
            boundary,
            deleter,
            new FixedTimeProvider(CreatedUtc));

        int exitCode = runner.Run(Command());

        Assert.Equal(HelperExitCodes.Failed, exitCode);
        Assert.Equal(2, deleter.CallCount);
        CompletionPayload result = CompletionTokenCodec.ParseAndValidate(
            Assert.IsType<byte[]>(boundary.Result),
            InstallId,
            new string('a', 64),
            key);
        Assert.Equal("Failed", result.Status);
    }

    [Fact]
    public void Does_not_mask_a_protected_result_write_failure()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        var boundary = new FakeBoundary(CreateWorkBytes(key)) { FailWrite = true };
        var runner = new HelperCommandRunner(
            boundary,
            new FakeDeleter(DeletionStatus.Completed, DeletionStatus.Completed),
            new FixedTimeProvider(CreatedUtc));

        Assert.Throws<IOException>(() => runner.Run(Command()));
        Assert.Equal(1, boundary.WriteCount);
    }

    private static HelperCommand Command() => new(
        @"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json",
        InstallId,
        @"C:\ProgramData\LemonSerialMonitor\Installer\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json");

    private static byte[] CreateWorkBytes(byte[] key)
    {
        ProtectedCompletionKey protectedKey = CompletionKeyProtection.Protect(key);
        var roots = new ApprovedRootManifest[]
        {
            new(
                @"C:\LemonTest\App",
                1,
                new string('1', 32),
                [],
                ApprovedRootRole.AppRoot),
            new(
                @"C:\LemonTest\AI",
                1,
                new string('2', 32),
                [],
                ApprovedRootRole.AiStateRoot),
        };
        var payload = new UninstallWorkPayload(
            InstallId.ToString("D"),
            new string('a', 64),
            protectedKey,
            roots);
        return UninstallWorkManifestCodec.GetStateFileBytes(
            UninstallWorkManifestCodec.Create(payload, key));
    }

    private sealed class FakeBoundary(byte[] manifest) : IProtectedStateBoundary
    {
        public byte[]? Result { get; private set; }
        public int WriteCount { get; private set; }
        public bool FailWrite { get; init; }

        public byte[] ReadManifest(HelperCommand command) => manifest.ToArray();

        public void WriteResult(HelperCommand command, byte[] result)
        {
            WriteCount++;
            if (FailWrite)
            {
                throw new IOException("simulated protected write failure");
            }

            Result = result.ToArray();
        }
    }

    private sealed class FakeDeleter(params DeletionStatus[] statuses)
        : IApprovedRootDeletionEngine
    {
        private readonly Queue<DeletionStatus> _statuses = new(statuses);
        public List<ApprovedRootManifest> Seen { get; } = [];

        public DeletionReport Execute(ApprovedRootManifest root)
        {
            Seen.Add(root);
            return new DeletionReport(_statuses.Dequeue(), []);
        }
    }

    private sealed class ThrowThenCompleteDeleter : IApprovedRootDeletionEngine
    {
        public int CallCount { get; private set; }

        public DeletionReport Execute(ApprovedRootManifest root)
        {
            CallCount++;
            if (CallCount == 1)
            {
                throw new IOException("simulated root failure");
            }

            return new DeletionReport(DeletionStatus.Completed, []);
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset utc) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => utc;
    }
}
