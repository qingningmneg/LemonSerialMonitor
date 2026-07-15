using System.Globalization;
using System.Runtime.Versioning;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ports;
using CommMonitor.Service.Sessions;

namespace CommMonitor.Service.Ipc;

internal interface IAiCommandDispatcher
{
    ValueTask<AiResponseEnvelope> DispatchAsync(
        AiRequestEnvelope request,
        PipeClientIdentity identity,
        CancellationToken cancellationToken);
}

[SupportedOSPlatform("windows")]
internal sealed class AiCommandDispatcher : IAiCommandDispatcher
{
    private const int MaximumIdentifierLength = 256;
    private const int MaximumTokenLength = 8192;
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();

    public static IReadOnlyList<string> ApprovedCommands { get; } =
    [
        AiCommandNames.Status,
        AiCommandNames.Ports,
        AiCommandNames.PrepareStart,
        AiCommandNames.CommitStart,
        AiCommandNames.RecoverLease,
        AiCommandNames.Pause,
        AiCommandNames.Resume,
        AiCommandNames.Stop,
        AiCommandNames.Sessions,
        AiCommandNames.Read,
        AiCommandNames.Wait,
        AiCommandNames.Export,
        AiCommandNames.Schema,
    ];

    private static readonly HashSet<string> ApprovedCommandSet =
        new(ApprovedCommands, StringComparer.Ordinal);

    private readonly CaptureCoordinator _coordinator;
    private readonly CaptureAuthority _authority;
    private readonly AiSessionService _sessions;
    private readonly IPortCatalog _ports;
    private readonly ICaptureSourceStatusProvider _captureSourceStatus;

    public AiCommandDispatcher(
        CaptureCoordinator coordinator,
        CaptureAuthority authority,
        AiSessionService sessions,
        IPortCatalog ports,
        ICaptureSourceStatusProvider captureSourceStatus)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _authority = authority ?? throw new ArgumentNullException(nameof(authority));
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
        _ports = ports ?? throw new ArgumentNullException(nameof(ports));
        _captureSourceStatus = captureSourceStatus ??
            throw new ArgumentNullException(nameof(captureSourceStatus));
    }

    public async ValueTask<AiResponseEnvelope> DispatchAsync(
        AiRequestEnvelope request,
        PipeClientIdentity identity,
        CancellationToken cancellationToken)
    {
        string requestId = NormalizeRequestId(request.RequestId);
        try
        {
            if (request.Version != AiProtocol.Version)
            {
                return Failure(
                    requestId,
                    AiErrorCodes.ProtocolMismatch,
                    $"AI protocol version {AiProtocol.Version} is required.",
                    retryable: false);
            }

            ValidateIdentifier(request.Command, nameof(request.Command));
            if (!ApprovedCommandSet.Contains(request.Command))
            {
                return Failure(
                    requestId,
                    AiErrorCodes.ProtocolMismatch,
                    "The requested AI command is not supported.",
                    retryable: false);
            }

            JsonElement result = await ExecuteAsync(
                request.Command,
                request.Arguments,
                identity,
                cancellationToken).ConfigureAwait(false);
            return new AiResponseEnvelope(
                AiProtocol.Version,
                requestId,
                true,
                result,
                null);
        }
        catch (Exception exception)
        {
            return MapFailure(requestId, exception, cancellationToken);
        }
    }

    private async ValueTask<JsonElement> ExecuteAsync(
        string command,
        JsonElement arguments,
        PipeClientIdentity identity,
        CancellationToken cancellationToken)
    {
        switch (command)
        {
            case AiCommandNames.Status:
                _ = Parse<EmptyArguments>(arguments);
                return Json(await GetStatusAsync(cancellationToken).ConfigureAwait(false));

            case AiCommandNames.Ports:
                _ = Parse<EmptyArguments>(arguments);
                return Json(await GetPortsAsync(cancellationToken).ConfigureAwait(false));

            case AiCommandNames.PrepareStart:
            {
                PrepareCaptureRequest request = Parse<PrepareCaptureRequest>(arguments);
                ValidateClientInstanceId(request.ClientInstanceId);
                if (request.DeviceIds is null || request.DeviceIds.Count == 0 ||
                    request.DeviceIds.Count > 256)
                {
                    throw new ArgumentException(
                        "DeviceIds must contain between 1 and 256 identifiers.");
                }

                if (request.Label is { Length: > MaximumIdentifierLength })
                {
                    throw new ArgumentException("Label is too long.");
                }

                IReadOnlySet<ulong> deviceIds = await ResolvePresentDevicesAsync(
                    request.DeviceIds,
                    cancellationToken).ConfigureAwait(false);
                PreparedLease prepared = await _authority.PrepareAiStartAsync(
                    Owner(identity, request.ClientInstanceId),
                    deviceIds,
                    request.Label,
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false);
                return Json(new PreparedCaptureDto(
                    prepared.ReservationId,
                    prepared.LeaseId,
                    prepared.Secret,
                    prepared.ClientInstanceId,
                    prepared.Generation.ToString(CultureInfo.InvariantCulture),
                    prepared.ExpiresAtUtc.UtcDateTime.ToString("O", CultureInfo.InvariantCulture)));
            }

            case AiCommandNames.CommitStart:
            {
                CommitCaptureRequest request = Parse<CommitCaptureRequest>(arguments);
                ValidateLeaseFields(
                    request.LeaseId,
                    request.LeaseSecret,
                    request.ClientInstanceId);
                ValidateIdentifier(request.ReservationId, nameof(request.ReservationId));
                ActiveLease active = await _authority.CommitAiStartAsync(
                    Owner(identity, request.ClientInstanceId),
                    request.ReservationId,
                    request.LeaseId,
                    request.LeaseSecret,
                    ParseGeneration(request.Generation),
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false);
                return Json(ToDto(active));
            }

            case AiCommandNames.RecoverLease:
            {
                RecoverLeaseRequest request = Parse<RecoverLeaseRequest>(arguments);
                ValidateLeaseFields(
                    request.LeaseId,
                    request.LeaseSecret,
                    request.ClientInstanceId);
                ActiveLease active = await _authority.RecoverLeaseAsync(
                    Owner(identity, request.ClientInstanceId),
                    request.LeaseId,
                    request.LeaseSecret,
                    ParseGeneration(request.Generation),
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false);
                return Json(ToDto(active));
            }

            case AiCommandNames.Pause:
            case AiCommandNames.Resume:
            case AiCommandNames.Stop:
            {
                LeaseProof request = Parse<LeaseProof>(arguments);
                ValidateLeaseFields(
                    request.LeaseId,
                    request.LeaseSecret,
                    request.ClientInstanceId);
                CaptureClientOwner owner = Owner(identity, request.ClientInstanceId);
                long generation = ParseGeneration(request.Generation);
                if (command == AiCommandNames.Stop)
                {
                    await _authority.StopAiAsync(
                        owner,
                        request.LeaseId,
                        request.LeaseSecret,
                        generation,
                        cancellationToken).ConfigureAwait(false);
                    return Json(await GetStatusAsync(cancellationToken).ConfigureAwait(false));
                }

                _ = command == AiCommandNames.Pause
                    ? await _authority.PauseAiAsync(
                        owner,
                        request.LeaseId,
                        request.LeaseSecret,
                        generation,
                        cancellationToken).ConfigureAwait(false)
                    : await _authority.ResumeAiAsync(
                        owner,
                        request.LeaseId,
                        request.LeaseSecret,
                        generation,
                        cancellationToken).ConfigureAwait(false);
                return Json(await GetStatusAsync(cancellationToken).ConfigureAwait(false));
            }

            case AiCommandNames.Sessions:
                return Json(await _sessions.ListAsync(
                    Parse<ListSessionsRequest>(arguments),
                    cancellationToken).ConfigureAwait(false));

            case AiCommandNames.Read:
                return Json(await _sessions.ReadAsync(
                    Parse<ReadEventsRequest>(arguments),
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false));

            case AiCommandNames.Wait:
                return Json(await _sessions.WaitAsync(
                    ConnectionId(identity),
                    Parse<WaitEventsRequest>(arguments),
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false));

            case AiCommandNames.Export:
                return Json(await _sessions.ExportAsync(
                    Parse<ExportSessionRequest>(arguments),
                    DateTimeOffset.UtcNow,
                    cancellationToken).ConfigureAwait(false));

            case AiCommandNames.Schema:
                _ = Parse<EmptyArguments>(arguments);
                return Json(CreateSchema());

            default:
                throw new InvalidOperationException("Unreachable AI command dispatch state.");
        }
    }

    private async Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken)
    {
        CaptureSourceStatus source = await _captureSourceStatus
            .GetStatusAsync(cancellationToken)
            .ConfigureAwait(false);
        CaptureSnapshot snapshot = _coordinator.Snapshot;
        bool gap = snapshot.DriverDropped > 0 || snapshot.ServiceDropped > 0;
        bool continuity = snapshot.StatsKnown && !gap && !snapshot.TruncationSeen;
        var integrity = new AiIntegrityDto(
            AiProtocol.Version,
            snapshot.StatsKnown,
            snapshot.StatsKnown
                ? snapshot.DriverDropped.ToString(CultureInfo.InvariantCulture)
                : null,
            snapshot.ServiceDropped.ToString(CultureInfo.InvariantCulture),
            snapshot.TruncationSeen,
            gap,
            continuity,
            snapshot.Complete,
            snapshot.StatsKnown
                ? snapshot.Statistics.SampledAtUtc.UtcDateTime.ToString(
                    "O",
                    CultureInfo.InvariantCulture)
                : null,
            snapshot.Generation.ToString(CultureInfo.InvariantCulture));
        IReadOnlyList<string> warnings = source.Kind == CaptureSourceStatusKind.Ready
            ? []
            : [source.Kind.ToString()];
        return new AiStatusDto(
            "available",
            MapDriverState(source.Kind),
            snapshot.State.ToString().ToLowerInvariant(),
            string.IsNullOrWhiteSpace(snapshot.OwnerType)
                ? "none"
                : snapshot.OwnerType.ToLowerInvariant(),
            snapshot.SessionId,
            snapshot.Generation.ToString(CultureInfo.InvariantCulture),
            integrity,
            warnings);
    }

    private async Task<IReadOnlyList<AiPortDto>> GetPortsAsync(
        CancellationToken cancellationToken)
    {
        IReadOnlyList<PortInfo> ports = await _ports
            .GetPortsAsync(cancellationToken)
            .ConfigureAwait(false);
        return ports
            .Select(static port => new AiPortDto(
                port.DeviceIdHash.ToString("X16", CultureInfo.InvariantCulture),
                port.Name,
                port.FriendlyName,
                true))
            .ToArray();
    }

    private async Task<IReadOnlySet<ulong>> ResolvePresentDevicesAsync(
        IReadOnlyList<string> requested,
        CancellationToken cancellationToken)
    {
        var parsed = new HashSet<ulong>();
        foreach (string value in requested)
        {
            if (value is null || value.Length != 16 ||
                !ulong.TryParse(
                    value,
                    NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture,
                    out ulong deviceId))
            {
                throw new ArgumentException(
                    "Each device ID must be exactly 16 hexadecimal characters.");
            }

            parsed.Add(deviceId);
        }

        IReadOnlyList<PortInfo> ports = await _ports
            .GetPortsAsync(cancellationToken)
            .ConfigureAwait(false);
        HashSet<ulong> present = ports.Select(static port => port.DeviceIdHash).ToHashSet();
        if (!parsed.IsSubsetOf(present))
        {
            throw new ArgumentException("One or more selected serial devices are not present.");
        }

        return parsed;
    }

    private static T Parse<T>(JsonElement arguments)
    {
        if (arguments.ValueKind != JsonValueKind.Object)
        {
            throw new ArgumentException("AI command arguments must be a JSON object.");
        }

        return arguments.Deserialize<T>(JsonOptions) ??
            throw new ArgumentException("AI command arguments cannot be null.");
    }

    private static string NormalizeRequestId(string requestId)
    {
        ValidateIdentifier(requestId, nameof(requestId));
        return requestId;
    }

    private static void ValidateIdentifier(string value, string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, name);
        if (value.Length > MaximumIdentifierLength ||
            value.Any(static character => char.IsControl(character)))
        {
            throw new ArgumentException($"{name} is invalid.", name);
        }
    }

    private static void ValidateClientInstanceId(string value) =>
        ValidateIdentifier(value, "ClientInstanceId");

    private static void ValidateLeaseFields(
        string leaseId,
        string secret,
        string clientInstanceId)
    {
        ValidateIdentifier(leaseId, nameof(leaseId));
        ValidateClientInstanceId(clientInstanceId);
        ArgumentException.ThrowIfNullOrWhiteSpace(secret);
        if (secret.Length > MaximumTokenLength)
        {
            throw new ArgumentException("LeaseSecret is too long.", nameof(secret));
        }
    }

    private static long ParseGeneration(string value)
    {
        if (!long.TryParse(
                value,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out long generation) ||
            generation < 0)
        {
            throw new ArgumentException("Generation must be a non-negative decimal Int64 string.");
        }

        return generation;
    }

    private static CaptureClientOwner Owner(
        PipeClientIdentity identity,
        string clientInstanceId) =>
        new(identity.Sid, identity.LogonLuid, clientInstanceId);

    private static string ConnectionId(PipeClientIdentity identity) =>
        identity.ConnectionId;

    private static ActiveCaptureDto ToDto(ActiveLease active) =>
        new(
            active.LeaseId,
            active.Secret,
            active.ClientInstanceId,
            active.Generation.ToString(CultureInfo.InvariantCulture),
            active.SessionId,
            active.CaptureState.ToString().ToLowerInvariant());

    private static string MapDriverState(CaptureSourceStatusKind kind) => kind switch
    {
        CaptureSourceStatusKind.Ready => "available",
        CaptureSourceStatusKind.DevelopmentFake => "development-fake",
        CaptureSourceStatusKind.DriverUnavailable => "unavailable",
        CaptureSourceStatusKind.ProtocolMismatch => "protocol-mismatch",
        _ => "faulted",
    };

    private static AiSchemaDto CreateSchema()
    {
        var schemas = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
        {
            ["commands"] = Json(new
            {
                allowed = ApprovedCommands,
                forbidden = new[] { "clear", "delete", "send", "inject", "replay" },
            }),
            ["deviceId"] = Json(new { type = "string", pattern = "^[0-9A-Fa-f]{16}$" }),
            ["sequence"] = Json(new { type = "string", pattern = "^[0-9]+$" }),
            ["event"] = Json(new
            {
                schemaVersion = AiProtocol.Version,
                payload = "payloadBase64",
                optionalViews = new[] { "payloadHex", "textPreview" },
            }),
        };
        return new AiSchemaDto(
            AiProtocol.Version,
            schemas,
            typeof(AiErrorCodes)
                .GetFields(System.Reflection.BindingFlags.Public |
                           System.Reflection.BindingFlags.Static)
                .Where(static field => field.IsLiteral && field.FieldType == typeof(string))
                .Select(static field => (string)field.GetRawConstantValue()!)
                .Order(StringComparer.Ordinal)
                .ToArray());
    }

    private static JsonElement Json<T>(T value) =>
        JsonSerializer.SerializeToElement(value, JsonOptions);

    private static AiResponseEnvelope MapFailure(
        string requestId,
        Exception exception,
        CancellationToken cancellationToken)
    {
        Exception failure = exception is AggregateException aggregate
            ? aggregate.GetBaseException()
            : exception;
        return failure switch
        {
            CaptureLeaseException lease => Failure(
                requestId,
                lease.Code,
                lease.Message,
                Retryable(lease.Code)),
            AiSessionException session => Failure(
                requestId,
                session.Code,
                session.Message,
                Retryable(session.Code)),
            AiCursorException cursor => Failure(
                requestId,
                cursor.Code,
                cursor.Message,
                Retryable(cursor.Code)),
            UnauthorizedAccessException denied => Failure(
                requestId,
                AiErrorCodes.AccessDenied,
                denied.Message,
                retryable: false),
            OperationCanceledException when cancellationToken.IsCancellationRequested => Failure(
                requestId,
                AiErrorCodes.Cancelled,
                "The AI request was cancelled.",
                retryable: true),
            TimeoutException => Failure(
                requestId,
                AiErrorCodes.Timeout,
                "The AI request timed out.",
                retryable: true),
            JsonException or ArgumentException or FormatException => Failure(
                requestId,
                AiErrorCodes.ProtocolMismatch,
                failure.Message,
                retryable: false),
            IOException => Failure(
                requestId,
                AiErrorCodes.ServiceUnavailable,
                "The service could not complete the storage or transport operation.",
                retryable: true),
            _ => Failure(
                requestId,
                AiErrorCodes.ServiceUnavailable,
                "The service could not complete the AI request.",
                retryable: true),
        };
    }

    private static bool Retryable(string code) => code is
        AiErrorCodes.ServiceUnavailable or
        AiErrorCodes.DriverUnavailable or
        AiErrorCodes.CaptureConflict or
        AiErrorCodes.Timeout or
        AiErrorCodes.Cancelled;

    private static AiResponseEnvelope Failure(
        string requestId,
        string code,
        string message,
        bool retryable) =>
        new(
            AiProtocol.Version,
            requestId,
            false,
            null,
            new AiError(
                code,
                message,
                retryable,
                Guid.NewGuid().ToString("N")));

    private sealed record EmptyArguments;
}
