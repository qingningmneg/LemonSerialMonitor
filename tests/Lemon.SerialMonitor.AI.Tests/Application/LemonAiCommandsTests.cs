using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Security;
using Lemon.SerialMonitor.AI.Transport;

namespace Lemon.SerialMonitor.AI.Tests.Application;

public sealed class LemonAiCommandsTests
{
    [Fact]
    public async Task Start_persists_pending_before_commit_and_never_returns_the_secret()
    {
        var steps = new List<string>();
        var client = new FakeClient(steps);
        var vault = new FakeVault(steps);
        var commands = new LemonAiCommands(client, vault, "client-1");

        CaptureStartResult result = await commands.StartCaptureAsync(
            ["0000000000000011"],
            "bench");

        Assert.Equal(
            ["prepare", "vault.write-pending", "commit", "vault.activate"],
            steps);
        Assert.Equal("lease-1", result.LeaseId);
        Assert.DoesNotContain("secret", System.Text.Json.JsonSerializer.Serialize(result));
    }

    [Fact]
    public async Task Stop_loads_proof_from_vault_then_removes_it_only_after_success()
    {
        var steps = new List<string>();
        var client = new FakeClient(steps);
        var vault = new FakeVault(steps)
        {
            Lease = CreateStoredLease(),
        };
        var commands = new LemonAiCommands(client, vault, "client-1");

        AiStatusDto status = await commands.StopCaptureAsync("lease-1");

        Assert.Equal("stopped", status.CaptureState);
        Assert.Equal(["vault.read", "stop", "vault.remove"], steps);
        Assert.Equal("secret-1", client.LastProof!.LeaseSecret);
    }

    private static StoredLease CreateStoredLease() =>
        new(
            "lease-1", "secret-1", "reservation-1", "client-1", "2",
            LeaseVaultState.Active, DateTimeOffset.MaxValue.ToString("O"), "session-1",
            DateTimeOffset.UtcNow.ToString("O"));

    private sealed class FakeVault(List<string> steps) : ILeaseVault
    {
        public StoredLease? Lease { get; set; }

        public Task<IReadOnlyList<StoredLease>> ReadAllAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<StoredLease>>(Lease is null ? [] : [Lease]);

        public Task<StoredLease?> ReadAsync(string leaseId, CancellationToken cancellationToken = default)
        {
            steps.Add("vault.read");
            return Task.FromResult(Lease);
        }

        public Task WritePendingAsync(PreparedCaptureDto prepared, CancellationToken cancellationToken = default)
        {
            steps.Add("vault.write-pending");
            Lease = new StoredLease(
                prepared.LeaseId, prepared.LeaseSecret, prepared.ReservationId,
                prepared.ClientInstanceId, prepared.Generation, LeaseVaultState.Pending,
                prepared.ExpiresAtUtc, null, DateTimeOffset.UtcNow.ToString("O"));
            return Task.CompletedTask;
        }

        public Task ActivateAsync(ActiveCaptureDto active, string reservationId, CancellationToken cancellationToken = default)
        {
            steps.Add("vault.activate");
            Lease = CreateStoredLease();
            return Task.CompletedTask;
        }

        public Task RemoveAsync(string leaseId, CancellationToken cancellationToken = default)
        {
            steps.Add("vault.remove");
            Lease = null;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeClient(List<string> steps) : IAiServiceClient
    {
        public LeaseProof? LastProof { get; private set; }

        public Task<PreparedCaptureDto> PrepareStartAsync(PrepareCaptureRequest request, CancellationToken cancellationToken = default)
        {
            steps.Add("prepare");
            return Task.FromResult(new PreparedCaptureDto(
                "reservation-1", "lease-1", "secret-1", request.ClientInstanceId, "1",
                DateTimeOffset.UtcNow.AddMinutes(1).ToString("O")));
        }

        public Task<ActiveCaptureDto> CommitStartAsync(CommitCaptureRequest request, CancellationToken cancellationToken = default)
        {
            steps.Add("commit");
            return Task.FromResult(new ActiveCaptureDto(
                request.LeaseId, "secret-2", request.ClientInstanceId, "2", "session-1", "running"));
        }

        public Task<AiStatusDto> StopAsync(LeaseProof request, CancellationToken cancellationToken = default)
        {
            LastProof = request;
            steps.Add("stop");
            return Task.FromResult(Status("stopped"));
        }

        public Task<AiStatusDto> PauseAsync(LeaseProof request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("paused"));

        public Task<AiStatusDto> ResumeAsync(LeaseProof request, CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("running"));

        public Task<ActiveCaptureDto> RecoverLeaseAsync(RecoverLeaseRequest request, CancellationToken cancellationToken = default) =>
            Task.FromResult(new ActiveCaptureDto(
                request.LeaseId, "rotated", request.ClientInstanceId, request.Generation,
                "session-1", "running"));

        public Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(Status("stopped"));

        public Task<IReadOnlyList<AiPortDto>> ListPortsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<AiPortDto>>([]);

        public Task<AiSessionPage> ListSessionsAsync(ListSessionsRequest request, CancellationToken cancellationToken = default) =>
            throw new NotImplementedException();

        public Task<AiEventPage> ReadEventsAsync(ReadEventsRequest request, CancellationToken cancellationToken = default) =>
            throw new NotImplementedException();

        public Task<AiEventPage> WaitEventsAsync(WaitEventsRequest request, CancellationToken cancellationToken = default) =>
            throw new NotImplementedException();

        public Task<AiExportDto> ExportAsync(ExportSessionRequest request, CancellationToken cancellationToken = default) =>
            throw new NotImplementedException();

        public Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken = default) =>
            throw new NotImplementedException();

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        private static AiStatusDto Status(string state) =>
            new(
                "available", "available", state, "ai", "session-1", "2",
                new AiIntegrityDto(1, true, "0", "0", false, false, true, true, null, "2"),
                []);
    }
}
