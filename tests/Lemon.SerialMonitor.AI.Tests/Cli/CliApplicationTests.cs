using System.Text.Json;
using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Cli;
using Lemon.SerialMonitor.AI.Security;
using Lemon.SerialMonitor.AI.Transport;

namespace Lemon.SerialMonitor.AI.Tests.Cli;

public sealed class CliApplicationTests
{
    [Fact]
    public async Task Status_writes_one_JSON_document_and_no_diagnostic()
    {
        var context = new CliContext();

        int exitCode = await context.RunAsync("status", "--json");

        Assert.Equal(CliExitCodes.Success, exitCode);
        using JsonDocument output = JsonDocument.Parse(context.Stdout.ToString());
        Assert.Equal("available", output.RootElement.GetProperty("serviceState").GetString());
        Assert.Equal(string.Empty, context.Stderr.ToString());
    }

    [Fact]
    public async Task Invalid_device_id_exits_two_without_preparing_capture()
    {
        var context = new CliContext();

        int exitCode = await context.RunAsync(
            "capture", "start", "--device-id", "COM3", "--json");

        Assert.Equal(CliExitCodes.InvalidArguments, exitCode);
        Assert.Equal(0, context.Client.PrepareCalls);
        using JsonDocument output = JsonDocument.Parse(context.Stdout.ToString());
        Assert.Equal("INVALID_ARGUMENTS", output.RootElement
            .GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task Start_output_never_contains_the_lease_secret()
    {
        var context = new CliContext();

        int exitCode = await context.RunAsync(
            "capture", "start",
            "--device-id", "0000000000000011",
            "--label", "bench",
            "--json");

        Assert.Equal(CliExitCodes.Success, exitCode);
        Assert.DoesNotContain("secret-value", context.Stdout.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("secret-value", context.Stderr.ToString(), StringComparison.Ordinal);
        using JsonDocument output = JsonDocument.Parse(context.Stdout.ToString());
        Assert.Equal("lease-1", output.RootElement.GetProperty("leaseId").GetString());
    }

    [Fact]
    public async Task Wait_jsonl_writes_events_then_one_page_metadata_line()
    {
        var context = new CliContext();

        int exitCode = await context.RunAsync(
            "events", "wait",
            "--session-id", "session-1",
            "--after-sequence", "0",
            "--allow-unverified-seek",
            "--timeout-seconds", "5",
            "--jsonl");

        Assert.Equal(CliExitCodes.Success, exitCode);
        string[] lines = context.Stdout.ToString().Split(
            Environment.NewLine,
            StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        using JsonDocument captureEvent = JsonDocument.Parse(lines[0]);
        Assert.Equal("1", captureEvent.RootElement.GetProperty("sequence").GetString());
        using JsonDocument page = JsonDocument.Parse(lines[1]);
        Assert.Equal("cursor-2", page.RootElement
            .GetProperty("_page").GetProperty("nextCursor").GetString());
    }

    [Fact]
    public async Task Conflicting_cursor_and_seek_are_rejected_without_a_service_call()
    {
        var context = new CliContext();

        int exitCode = await context.RunAsync(
            "events", "read",
            "--session-id", "session-1",
            "--cursor", "cursor-1",
            "--after-sequence", "0",
            "--allow-unverified-seek",
            "--json");

        Assert.Equal(CliExitCodes.InvalidArguments, exitCode);
        Assert.Equal(0, context.Client.ReadCalls);
    }

    private sealed class CliContext
    {
        public CliContext()
        {
            Client = new FakeClient();
            Vault = new MemoryVault();
            Stdout = new StringWriter();
            Stderr = new StringWriter();
            Application = new CliApplication(
                new LemonAiCommands(Client, Vault, "client-1"),
                Stdout,
                Stderr);
        }

        public FakeClient Client { get; }

        public MemoryVault Vault { get; }

        public StringWriter Stdout { get; }

        public StringWriter Stderr { get; }

        public CliApplication Application { get; }

        public Task<int> RunAsync(params string[] arguments) =>
            Application.RunAsync(arguments);
    }

    private sealed class MemoryVault : ILeaseVault
    {
        private StoredLease? _lease;

        public Task<IReadOnlyList<StoredLease>> ReadAllAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<StoredLease>>(_lease is null ? [] : [_lease]);

        public Task<StoredLease?> ReadAsync(string leaseId, CancellationToken cancellationToken = default) =>
            Task.FromResult(_lease);

        public Task WritePendingAsync(PreparedCaptureDto prepared, CancellationToken cancellationToken = default)
        {
            _lease = new StoredLease(
                prepared.LeaseId, prepared.LeaseSecret, prepared.ReservationId,
                prepared.ClientInstanceId, prepared.Generation, LeaseVaultState.Pending,
                prepared.ExpiresAtUtc, null, DateTimeOffset.UtcNow.ToString("O"));
            return Task.CompletedTask;
        }

        public Task ActivateAsync(ActiveCaptureDto active, string reservationId, CancellationToken cancellationToken = default)
        {
            _lease = new StoredLease(
                active.LeaseId, active.LeaseSecret, reservationId,
                active.ClientInstanceId, active.Generation, LeaseVaultState.Active,
                DateTimeOffset.MaxValue.ToString("O"), active.SessionId,
                DateTimeOffset.UtcNow.ToString("O"));
            return Task.CompletedTask;
        }

        public Task RemoveAsync(string leaseId, CancellationToken cancellationToken = default)
        {
            _lease = null;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeClient : IAiServiceClient
    {
        public int PrepareCalls { get; private set; }

        public int ReadCalls { get; private set; }

        public Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("stopped"));

        public Task<IReadOnlyList<AiPortDto>> ListPortsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<AiPortDto>>([
                new AiPortDto("0000000000000011", "COM3", "USB serial", true),
            ]);

        public Task<PreparedCaptureDto> PrepareStartAsync(PrepareCaptureRequest request, CancellationToken cancellationToken = default)
        {
            PrepareCalls++;
            return Task.FromResult(new PreparedCaptureDto(
                "reservation-1", "lease-1", "secret-value", request.ClientInstanceId, "1",
                DateTimeOffset.UtcNow.AddMinutes(1).ToString("O")));
        }

        public Task<ActiveCaptureDto> CommitStartAsync(CommitCaptureRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new ActiveCaptureDto(
                request.LeaseId, request.LeaseSecret, request.ClientInstanceId, "2",
                "session-1", "running"));

        public Task<ActiveCaptureDto> RecoverLeaseAsync(RecoverLeaseRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new ActiveCaptureDto(
                request.LeaseId, request.LeaseSecret, request.ClientInstanceId,
                request.Generation, "session-1", "running"));

        public Task<AiStatusDto> PauseAsync(LeaseProof request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("paused"));

        public Task<AiStatusDto> ResumeAsync(LeaseProof request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("running"));

        public Task<AiStatusDto> StopAsync(LeaseProof request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("stopped"));

        public Task<AiSessionPage> ListSessionsAsync(ListSessionsRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new AiSessionPage([], null, false));

        public Task<AiEventPage> ReadEventsAsync(ReadEventsRequest request, CancellationToken cancellationToken = default)
        {
            ReadCalls++;
            return Task.FromResult(Page());
        }

        public Task<AiEventPage> WaitEventsAsync(WaitEventsRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Page());

        public Task<AiExportDto> ExportAsync(ExportSessionRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new AiExportDto(
                "export-1", "session.jsonl", "C:\\Exports\\session.jsonl", "jsonl",
                "10", new string('A', 64), DateTimeOffset.UtcNow.ToString("O")));

        public Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(new AiSchemaDto(1, new Dictionary<string, JsonElement>(), []));

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        private static AiStatusDto Status(string state) =>
            new(
                "available", "available", state, "none", null, "0",
                Integrity(), []);

        private static AiEventPage Page() =>
            new(
                [new AiEventDto(
                    1, "1", "1", DateTimeOffset.UtcNow.ToString("O"), "1",
                    "0000000000000011", "COM3", 1, "tool.exe", "available", "Read",
                    "0x00000000", "0x00000000", 1, 1, 1, [], "QQ==", null, null, false)],
                "cursor-2", false, "1", "receipt-2", Integrity(), []);

        private static AiIntegrityDto Integrity() =>
            new(1, true, "0", "0", false, false, true, true, null, "0");
    }
}
