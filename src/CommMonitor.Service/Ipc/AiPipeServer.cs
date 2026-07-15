using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Ipc;
using CommMonitor.Service.Security;

namespace CommMonitor.Service.Ipc;

[SupportedOSPlatform("windows")]
internal sealed class AiPipeServer : BackgroundService
{
    public const int MaximumServerInstances = 8;
    internal static readonly TimeSpan DefaultInitialRequestTimeout =
        TimeSpan.FromSeconds(10);
    internal static readonly JsonFrameOptions FrameOptions =
        new(AiProtocol.MaximumResponseBytes, MaximumDepth: 64);

    private readonly IAiCommandDispatcher _dispatcher;
    private readonly IPipeClientIdentityProvider _identityProvider;
    private readonly InstallSecurityOptions _securityOptions;
    private readonly ILogger<AiPipeServer> _logger;
    private readonly string _pipeName;
    private readonly TimeSpan _initialRequestTimeout;

    public AiPipeServer(
        IAiCommandDispatcher dispatcher,
        IPipeClientIdentityProvider identityProvider,
        InstallSecurityOptions securityOptions,
        ILogger<AiPipeServer> logger)
        : this(
            dispatcher,
            identityProvider,
            securityOptions,
            logger,
            AiProtocol.PipeName,
            DefaultInitialRequestTimeout)
    {
    }

    internal AiPipeServer(
        IAiCommandDispatcher dispatcher,
        IPipeClientIdentityProvider identityProvider,
        InstallSecurityOptions securityOptions,
        ILogger<AiPipeServer> logger,
        string pipeName,
        TimeSpan? initialRequestTimeout = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _identityProvider = identityProvider ??
            throw new ArgumentNullException(nameof(identityProvider));
        _securityOptions = securityOptions ??
            throw new ArgumentNullException(nameof(securityOptions));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        TimeSpan timeout = initialRequestTimeout ?? DefaultInitialRequestTimeout;
        if (timeout <= TimeSpan.Zero || timeout == Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(initialRequestTimeout));
        }
        _securityOptions.Validate();
        _pipeName = pipeName;
        _initialRequestTimeout = timeout;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation(
            "AI named-pipe endpoint {PipeName} is listening with {InstanceCount} instances.",
            _pipeName,
            MaximumServerInstances);
        Task[] listeners = Enumerable
            .Range(0, MaximumServerInstances)
            .Select(_ => ListenAsync(stoppingToken))
            .ToArray();
        await Task.WhenAll(listeners).ConfigureAwait(false);
    }

    internal static PipeSecurity CreatePipeSecurity(SecurityIdentifier authorizedUser)
    {
        ArgumentNullException.ThrowIfNull(authorizedUser);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACLs require Windows.");
        }

        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddRule(
            security,
            new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
            AccessControlType.Deny);
        AddRule(
            security,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow);
        AddRule(
            security,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow);
        AddRule(
            security,
            authorizedUser,
            PipeAccessRights.ReadWrite,
            AccessControlType.Allow);
        SecurityIdentifier serverIdentity = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The service identity does not have a SID.");
        AddRule(
            security,
            serverIdentity,
            PipeAccessRights.CreateNewInstance,
            AccessControlType.Allow);
        return security;
    }

    private async Task ListenAsync(CancellationToken stoppingToken)
    {
        SecurityIdentifier authorized = new(_securityOptions.AuthorizedUserSid);
        while (!stoppingToken.IsCancellationRequested)
        {
            await using NamedPipeServerStream pipe = NamedPipeServerStreamAcl.Create(
                _pipeName,
                PipeDirection.InOut,
                MaximumServerInstances,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous,
                0,
                0,
                CreatePipeSecurity(authorized));
            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
                await HandleClientAsync(pipe, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException exception)
            {
                _logger.LogDebug(exception, "AI pipe client did not send its initial frame in time.");
            }
            catch (EndOfStreamException)
            {
                // Normal client disconnect.
            }
            catch (IOException exception)
            {
                _logger.LogDebug(exception, "AI pipe client disconnected.");
            }
            catch (Exception exception)
            {
                _logger.LogError(exception, "AI pipe listener failed and will be recreated.");
            }
        }
    }

    private async Task HandleClientAsync(
        NamedPipeServerStream pipe,
        CancellationToken stoppingToken)
    {
        PipeClientIdentity identity;
        bool authorized;
        try
        {
            identity = _identityProvider.GetIdentity(pipe);
            authorized = IsAuthorized(identity);
        }
        catch (Exception exception)
        {
            _logger.LogWarning(exception, "AI client identity verification failed.");
            return;
        }

        if (!authorized)
        {
            _logger.LogWarning(
                "Rejected AI pipe client process {ProcessId} for SID {Sid} before reading a request.",
                identity.ProcessId,
                identity.Sid);
            return;
        }

        bool firstRequest = true;
        while (pipe.IsConnected && !stoppingToken.IsCancellationRequested)
        {
            AiRequestEnvelope request;
            if (firstRequest)
            {
                using var initialRequest = CancellationTokenSource.CreateLinkedTokenSource(
                    stoppingToken);
                initialRequest.CancelAfter(_initialRequestTimeout);
                request = await LengthPrefixedJsonCodec.ReadAsync<AiRequestEnvelope>(
                    pipe,
                    FrameOptions,
                    initialRequest.Token).ConfigureAwait(false);
                firstRequest = false;
            }
            else
            {
                request = await LengthPrefixedJsonCodec.ReadAsync<AiRequestEnvelope>(
                    pipe,
                    FrameOptions,
                    stoppingToken).ConfigureAwait(false);
            }

            long started = Stopwatch.GetTimestamp();
            AiResponseEnvelope response = await _dispatcher.DispatchAsync(
                request,
                identity,
                stoppingToken).ConfigureAwait(false);
            await LengthPrefixedJsonCodec.WriteAsync(
                pipe,
                response,
                FrameOptions,
                stoppingToken).ConfigureAwait(false);
            _logger.LogInformation(
                "AI command {Command} completed with {Code} in {ElapsedMilliseconds} ms for SID {Sid} and correlation {CorrelationId}.",
                request.Command,
                response.Success ? "OK" : response.Error?.Code,
                Stopwatch.GetElapsedTime(started).TotalMilliseconds,
                identity.Sid,
                response.Error?.CorrelationId ?? request.RequestId);
        }
    }

    private bool IsAuthorized(PipeClientIdentity identity)
    {
        if (!string.Equals(
                identity.Sid,
                _securityOptions.AuthorizedUserSid,
                StringComparison.Ordinal) ||
            identity.LogonLuid == 0)
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(_securityOptions.AuthorizedClientImagePath))
        {
            return true;
        }

        return string.Equals(
                   Path.GetFullPath(identity.FinalImagePath),
                   Path.GetFullPath(_securityOptions.AuthorizedClientImagePath),
                   StringComparison.OrdinalIgnoreCase) &&
               string.Equals(
                   identity.Sha256,
                   _securityOptions.AuthorizedClientSha256,
                   StringComparison.Ordinal);
    }

    private static void AddRule(
        PipeSecurity security,
        SecurityIdentifier sid,
        PipeAccessRights rights,
        AccessControlType accessControlType) =>
        security.AddAccessRule(new PipeAccessRule(sid, rights, accessControlType));
}
