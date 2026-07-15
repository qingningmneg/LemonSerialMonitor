using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Ipc;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Security;
using Microsoft.Extensions.Logging.Abstractions;

namespace CommMonitor.Service.Tests.Ipc;

[SupportedOSPlatform("windows")]
public sealed class AiPipeServerTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(10);

    [Fact]
    public void Approved_command_registry_is_exact_and_contains_no_mutating_serial_commands()
    {
        Assert.Equal(
            [
                "status", "ports", "prepare-start", "commit-start", "recover-lease",
                "pause", "resume", "stop", "sessions", "read", "wait", "export", "schema",
            ],
            AiCommandDispatcher.ApprovedCommands);
        Assert.DoesNotContain(
            AiCommandDispatcher.ApprovedCommands,
            command => command is "clear" or "delete" or "send" or "inject" or "replay");
    }

    [Fact]
    public void Pipe_security_allows_only_system_administrators_and_the_authorized_user()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        SecurityIdentifier authorized = WindowsIdentity.GetCurrent().User!;
        PipeAccessRule[] rules = AiPipeServer.CreatePipeSecurity(authorized)
            .GetAccessRules(true, false, typeof(SecurityIdentifier))
            .Cast<PipeAccessRule>()
            .ToArray();

        AssertAllow(rules, authorized, PipeAccessRights.ReadWrite);
        AssertAllow(
            rules,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl);
        AssertAllow(
            rules,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl);
        Assert.DoesNotContain(
            rules,
            rule => rule.IdentityReference.Equals(
                new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null)));
        Assert.Contains(
            rules,
            rule => rule.AccessControlType == AccessControlType.Deny &&
                    rule.IdentityReference.Equals(
                        new SecurityIdentifier(WellKnownSidType.NetworkSid, null)));
    }

    [Fact]
    public async Task Eight_clients_can_connect_independently_and_receive_correlated_responses()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string sid = WindowsIdentity.GetCurrent().User!.Value;
        string pipeName = $"Lemon.AiPipeServerTests.{Guid.NewGuid():N}";
        var identity = new PipeClientIdentity(
            Environment.ProcessId,
            sid,
            42,
            Environment.ProcessPath!,
            new string('a', 64));
        var options = new InstallSecurityOptions
        {
            CoreRootMetadataPath = Path.GetTempPath(),
            AuthorizedUserSid = sid,
            AuthorizedClientImagePath = identity.FinalImagePath,
            AuthorizedClientSha256 = identity.Sha256,
        };
        var dispatcher = new EchoDispatcher();
        using var server = new AiPipeServer(
            dispatcher,
            new StaticIdentityProvider(identity),
            options,
            NullLogger<AiPipeServer>.Instance,
            pipeName);
        await server.StartAsync(CancellationToken.None);
        var clients = new List<NamedPipeClientStream>();
        try
        {
            Task<NamedPipeClientStream>[] connections = Enumerable
                .Range(0, AiPipeServer.MaximumServerInstances)
                .Select(_ => ConnectAsync(pipeName))
                .ToArray();
            clients.AddRange(await Task.WhenAll(connections));

            Task[] calls = clients.Select(async (client, index) =>
            {
                string requestId = $"request-{index}";
                JsonElement arguments = JsonSerializer.SerializeToElement(
                    new { value = index },
                    AiJson.CreateOptions());
                await LengthPrefixedJsonCodec.WriteAsync(
                    client,
                    new AiRequestEnvelope(
                        AiProtocol.Version,
                        requestId,
                        AiCommandNames.Status,
                        arguments),
                    AiPipeServer.FrameOptions);
                AiResponseEnvelope response = await LengthPrefixedJsonCodec.ReadAsync<AiResponseEnvelope>(
                    client,
                    AiPipeServer.FrameOptions);
                Assert.True(response.Success, response.Error?.Message);
                Assert.Equal(requestId, response.RequestId);
            }).ToArray();
            await Task.WhenAll(calls).WaitAsync(TestTimeout);
            Assert.Equal(AiPipeServer.MaximumServerInstances, dispatcher.CallCount);
        }
        finally
        {
            foreach (NamedPipeClientStream client in clients)
            {
                await client.DisposeAsync();
            }

            await server.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task Identity_mismatch_is_disconnected_before_a_request_is_read()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string sid = WindowsIdentity.GetCurrent().User!.Value;
        string pipeName = $"Lemon.AiPipeServerTests.{Guid.NewGuid():N}";
        var options = new InstallSecurityOptions
        {
            CoreRootMetadataPath = Path.GetTempPath(),
            AuthorizedUserSid = sid,
            AuthorizedClientImagePath = Environment.ProcessPath!,
            AuthorizedClientSha256 = new string('a', 64),
        };
        var dispatcher = new EchoDispatcher();
        var wrongIdentity = new PipeClientIdentity(
            Environment.ProcessId,
            sid,
            42,
            Environment.ProcessPath!,
            new string('b', 64));
        using var server = new AiPipeServer(
            dispatcher,
            new StaticIdentityProvider(wrongIdentity),
            options,
            NullLogger<AiPipeServer>.Instance,
            pipeName);
        await server.StartAsync(CancellationToken.None);
        try
        {
            await using NamedPipeClientStream client = await ConnectAsync(pipeName);
            await AssertServerDisconnectedAsync(client);
            Assert.Equal(0, dispatcher.CallCount);
        }
        finally
        {
            await server.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task Authorized_client_that_sends_no_frame_is_disconnected_after_initial_timeout()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string sid = WindowsIdentity.GetCurrent().User!.Value;
        string pipeName = $"Lemon.AiPipeServerTests.{Guid.NewGuid():N}";
        var identity = new PipeClientIdentity(
            Environment.ProcessId,
            sid,
            42,
            Environment.ProcessPath!,
            new string('a', 64));
        var options = new InstallSecurityOptions
        {
            CoreRootMetadataPath = Path.GetTempPath(),
            AuthorizedUserSid = sid,
            AuthorizedClientImagePath = identity.FinalImagePath,
            AuthorizedClientSha256 = identity.Sha256,
        };
        var dispatcher = new EchoDispatcher();
        using var server = new AiPipeServer(
            dispatcher,
            new StaticIdentityProvider(identity),
            options,
            NullLogger<AiPipeServer>.Instance,
            pipeName,
            TimeSpan.FromMilliseconds(100));
        await server.StartAsync(CancellationToken.None);
        try
        {
            await using NamedPipeClientStream client = await ConnectAsync(pipeName);
            await AssertServerDisconnectedAsync(client);
            Assert.Equal(0, dispatcher.CallCount);
        }
        finally
        {
            await server.StopAsync(CancellationToken.None);
        }
    }

    private static async Task AssertServerDisconnectedAsync(NamedPipeClientStream client)
    {
        byte[] buffer = new byte[1];
        using var cancellation = new CancellationTokenSource(TestTimeout);
        try
        {
            int count = await client.ReadAsync(buffer, cancellation.Token);
            Assert.Equal(0, count);
        }
        catch (IOException)
        {
            // Windows may report a closed server end as either EOF or a broken pipe.
        }
    }

    private static async Task<NamedPipeClientStream> ConnectAsync(string pipeName)
    {
        var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        using var cancellation = new CancellationTokenSource(TestTimeout);
        await client.ConnectAsync(cancellation.Token);
        return client;
    }

    private static void AssertAllow(
        IEnumerable<PipeAccessRule> rules,
        SecurityIdentifier sid,
        PipeAccessRights rights) =>
        Assert.Contains(
            rules,
            rule => rule.AccessControlType == AccessControlType.Allow &&
                    rule.IdentityReference.Equals(sid) &&
                    (rule.PipeAccessRights & rights) == rights);

    private sealed class StaticIdentityProvider(PipeClientIdentity identity) :
        IPipeClientIdentityProvider
    {
        public PipeClientIdentity GetIdentity(NamedPipeServerStream pipe) => identity;
    }

    private sealed class EchoDispatcher : IAiCommandDispatcher
    {
        private int _callCount;

        public int CallCount => Volatile.Read(ref _callCount);

        public ValueTask<AiResponseEnvelope> DispatchAsync(
            AiRequestEnvelope request,
            PipeClientIdentity identity,
            CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _callCount);
            JsonElement result = JsonSerializer.SerializeToElement(
                new { accepted = true },
                AiJson.CreateOptions());
            return ValueTask.FromResult(new AiResponseEnvelope(
                AiProtocol.Version,
                request.RequestId,
                true,
                result,
                null));
        }
    }
}
