using System.IO.Pipes;

namespace CommMonitor.Service.Ipc;

internal sealed record PipeClientIdentity(
    int ProcessId,
    string Sid,
    ulong LogonLuid,
    string FinalImagePath,
    string Sha256)
{
    public string ConnectionId { get; init; } = Guid.NewGuid().ToString("N");
}

internal interface IPipeClientIdentityProvider
{
    PipeClientIdentity GetIdentity(NamedPipeServerStream pipe);
}
