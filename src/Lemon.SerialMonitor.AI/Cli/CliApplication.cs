using System.Globalization;
using System.Text.Json;
using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Transport;

namespace Lemon.SerialMonitor.AI.Cli;

public sealed class CliApplication
{
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();
    private readonly LemonAiCommands _commands;
    private readonly TextWriter _stdout;
    private readonly TextWriter _stderr;

    public CliApplication(
        LemonAiCommands commands,
        TextWriter? stdout = null,
        TextWriter? stderr = null)
    {
        _commands = commands ?? throw new ArgumentNullException(nameof(commands));
        _stdout = stdout ?? Console.Out;
        _stderr = stderr ?? Console.Error;
    }

    public async Task<int> RunAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        try
        {
            if (arguments.Count == 0)
            {
                throw Usage("A command is required.");
            }

            string command = arguments[0];
            object? result;
            bool jsonLines = false;
            switch (command)
            {
                case "status":
                    RequireOnlyFlags(arguments, 1, "--json");
                    result = await _commands.GetStatusAsync(cancellationToken).ConfigureAwait(false);
                    break;

                case "ports":
                    RequireOnlyFlags(arguments, 1, "--json");
                    result = await _commands.ListPortsAsync(cancellationToken).ConfigureAwait(false);
                    break;

                case "capture":
                    result = await RunCaptureAsync(arguments, cancellationToken).ConfigureAwait(false);
                    break;

                case "sessions":
                    result = await RunSessionsAsync(arguments, cancellationToken).ConfigureAwait(false);
                    break;

                case "events":
                    (result, jsonLines) = await RunEventsAsync(arguments, cancellationToken)
                        .ConfigureAwait(false);
                    break;

                case "export":
                    result = await RunExportAsync(arguments, cancellationToken).ConfigureAwait(false);
                    break;

                case "schema":
                    RequireOnlyFlags(arguments, 1, "--json");
                    result = await _commands.GetSchemaAsync(cancellationToken).ConfigureAwait(false);
                    break;

                default:
                    throw Usage($"Unknown command '{command}'.");
            }

            if (jsonLines)
            {
                await WriteJsonLinesAsync((AiEventPage)result!).ConfigureAwait(false);
            }
            else
            {
                await WriteJsonAsync(result!).ConfigureAwait(false);
            }

            return CliExitCodes.Success;
        }
        catch (CliUsageException exception)
        {
            await WriteErrorAsync(
                "INVALID_ARGUMENTS",
                exception.Message,
                retryable: false,
                correlationId: null).ConfigureAwait(false);
            return CliExitCodes.InvalidArguments;
        }
        catch (LemonAiException exception)
        {
            await WriteJsonAsync(new { success = false, error = exception.Error })
                .ConfigureAwait(false);
            await _stderr.WriteLineAsync(
                $"{exception.Code}: {exception.Message} ({exception.CorrelationId})")
                .ConfigureAwait(false);
            return MapExitCode(exception.Code);
        }
        catch (TimeoutException exception)
        {
            await WriteErrorAsync(
                AiErrorCodes.Timeout,
                exception.Message,
                retryable: true,
                correlationId: null).ConfigureAwait(false);
            return CliExitCodes.TimeoutOrCancelled;
        }
        catch (OperationCanceledException)
        {
            await WriteErrorAsync(
                AiErrorCodes.Cancelled,
                "The operation was cancelled.",
                retryable: true,
                correlationId: null).ConfigureAwait(false);
            return CliExitCodes.TimeoutOrCancelled;
        }
        catch (Exception exception)
        {
            string correlationId = Guid.NewGuid().ToString("N");
            await WriteErrorAsync(
                AiErrorCodes.ServiceUnavailable,
                "The AI command could not be completed.",
                retryable: true,
                correlationId).ConfigureAwait(false);
            await _stderr.WriteLineAsync(
                $"Unexpected error ({correlationId}): {exception.Message}")
                .ConfigureAwait(false);
            return CliExitCodes.Unexpected;
        }
    }

    private async Task<object> RunCaptureAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (arguments.Count < 2)
        {
            throw Usage("capture requires start, pause, resume, or stop.");
        }

        string action = arguments[1];
        OptionSet options = ParseOptions(arguments, 2);
        options.RequireFlag("--json");
        if (action == "start")
        {
            options.Allow("--device-id", multiple: true);
            options.Allow("--label");
            IReadOnlyList<string> deviceIds = options.RequireMany("--device-id");
            foreach (string deviceId in deviceIds)
            {
                if (deviceId.Length != 16 ||
                    !ulong.TryParse(
                        deviceId,
                        NumberStyles.AllowHexSpecifier,
                        CultureInfo.InvariantCulture,
                        out _))
                {
                    throw Usage("--device-id must be exactly 16 hexadecimal characters.");
                }
            }

            string? label = options.OptionalSingle("--label");
            options.EnsureConsumed();
            await _commands.ReconcileAsync(cancellationToken).ConfigureAwait(false);
            return await _commands.StartCaptureAsync(deviceIds, label, cancellationToken)
                .ConfigureAwait(false);
        }

        if (action is "pause" or "resume" or "stop")
        {
            options.Allow("--lease-id");
            string leaseId = options.RequireSingle("--lease-id");
            options.EnsureConsumed();
            await _commands.ReconcileAsync(cancellationToken).ConfigureAwait(false);
            return action switch
            {
                "pause" => await _commands.PauseCaptureAsync(leaseId, cancellationToken)
                    .ConfigureAwait(false),
                "resume" => await _commands.ResumeCaptureAsync(leaseId, cancellationToken)
                    .ConfigureAwait(false),
                _ => await _commands.StopCaptureAsync(leaseId, cancellationToken)
                    .ConfigureAwait(false),
            };
        }

        throw Usage($"Unknown capture action '{action}'.");
    }

    private async Task<object> RunSessionsAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (arguments.Count < 2 || arguments[1] != "list")
        {
            throw Usage("sessions requires the list action.");
        }

        OptionSet options = ParseOptions(arguments, 2);
        options.RequireFlag("--json");
        options.Allow("--cursor");
        options.Allow("--limit");
        int limit = ParsePageLimit(options.OptionalSingle("--limit"));
        string? cursor = options.OptionalSingle("--cursor");
        options.EnsureConsumed();
        return await _commands.ListSessionsAsync(
            new ListSessionsRequest(cursor, limit),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<(object Result, bool JsonLines)> RunEventsAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        if (arguments.Count < 2 || arguments[1] is not ("read" or "wait"))
        {
            throw Usage("events requires the read or wait action.");
        }

        bool wait = arguments[1] == "wait";
        OptionSet options = ParseOptions(arguments, 2);
        if (wait)
        {
            options.RequireFlag("--jsonl");
        }
        else
        {
            options.RequireFlag("--json");
        }

        foreach ((string name, bool multiple) in new[]
                 {
                     ("--session-id", false), ("--cursor", false),
                     ("--resume-receipt", false), ("--after-sequence", false),
                     ("--limit", false), ("--timeout-seconds", false),
                     ("--device-id", true), ("--kind", true),
                     ("--from-utc", false), ("--to-utc", false),
                     ("--text-preview-max-bytes", false),
                 })
        {
            options.Allow(name, multiple);
        }
        options.AllowFlag("--allow-unverified-seek");
        options.AllowFlag("--include-hex");
        options.AllowFlag("--include-text-preview");

        string sessionId = options.RequireSingle("--session-id");
        string? cursor = options.OptionalSingle("--cursor");
        string? receipt = options.OptionalSingle("--resume-receipt");
        string? after = options.OptionalSingle("--after-sequence");
        bool allowSeek = options.ConsumeFlag("--allow-unverified-seek");
        if (cursor is not null && after is not null)
        {
            throw Usage("--cursor and --after-sequence cannot be used together.");
        }
        if (after is not null && !allowSeek)
        {
            throw Usage("--after-sequence requires --allow-unverified-seek.");
        }
        if (after is not null &&
            (!long.TryParse(after, NumberStyles.None, CultureInfo.InvariantCulture, out long sequence) ||
             sequence < 0))
        {
            throw Usage("--after-sequence must be a non-negative decimal Int64 value.");
        }

        int limit = ParsePageLimit(options.OptionalSingle("--limit"));
        int textPreviewMax = ParseBoundedInt(
            options.OptionalSingle("--text-preview-max-bytes"),
            256,
            1,
            4096,
            "--text-preview-max-bytes");
        IReadOnlyList<string>? devices = options.OptionalMany("--device-id");
        IReadOnlyList<string>? kinds = options.OptionalMany("--kind");
        var filter = new AiEventFilter(
            devices,
            kinds,
            options.OptionalSingle("--from-utc"),
            options.OptionalSingle("--to-utc"),
            options.ConsumeFlag("--include-hex"),
            options.ConsumeFlag("--include-text-preview"),
            textPreviewMax);

        if (wait)
        {
            int timeout = ParseBoundedInt(
                options.OptionalSingle("--timeout-seconds"),
                30,
                1,
                30,
                "--timeout-seconds");
            options.EnsureConsumed();
            AiEventPage page = await _commands.WaitEventsAsync(
                new WaitEventsRequest(
                    sessionId,
                    cursor,
                    receipt,
                    after,
                    allowSeek,
                    limit,
                    filter,
                    timeout),
                cancellationToken).ConfigureAwait(false);
            return (page, true);
        }

        if (options.OptionalSingle("--timeout-seconds") is not null)
        {
            throw Usage("--timeout-seconds is valid only for events wait.");
        }
        options.EnsureConsumed();
        AiEventPage readPage = await _commands.ReadEventsAsync(
            new ReadEventsRequest(
                sessionId,
                cursor,
                receipt,
                after,
                allowSeek,
                limit,
                filter),
            cancellationToken).ConfigureAwait(false);
        return (readPage, false);
    }

    private async Task<object> RunExportAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        OptionSet options = ParseOptions(arguments, 1);
        options.RequireFlag("--json");
        options.Allow("--session-id");
        options.Allow("--format");
        options.Allow("--label");
        string sessionId = options.RequireSingle("--session-id");
        string format = options.RequireSingle("--format").ToLowerInvariant();
        if (format is not ("json" or "jsonl" or "csv" or "txt" or "raw"))
        {
            throw Usage("--format must be json, jsonl, csv, txt, or raw.");
        }

        string? label = options.OptionalSingle("--label");
        options.EnsureConsumed();
        return await _commands.ExportAsync(
            new ExportSessionRequest(sessionId, format, label),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task WriteJsonLinesAsync(AiEventPage page)
    {
        foreach (AiEventDto captureEvent in page.Events)
        {
            await WriteJsonAsync(captureEvent).ConfigureAwait(false);
        }

        await WriteJsonAsync(new
        {
            _page = new
            {
                page.NextCursor,
                page.ResumeReceipt,
                page.HasMore,
                page.ScannedThroughSequence,
                page.Integrity,
                page.Warnings,
            },
        }).ConfigureAwait(false);
    }

    private async Task WriteJsonAsync(object value)
    {
        string json = JsonSerializer.Serialize(value, value.GetType(), JsonOptions);
        await _stdout.WriteLineAsync(json).ConfigureAwait(false);
    }

    private async Task WriteErrorAsync(
        string code,
        string message,
        bool retryable,
        string? correlationId)
    {
        string correlation = correlationId ?? Guid.NewGuid().ToString("N");
        await WriteJsonAsync(new
        {
            success = false,
            error = new AiError(code, message, retryable, correlation),
        }).ConfigureAwait(false);
        await _stderr.WriteLineAsync($"{code}: {message} ({correlation})")
            .ConfigureAwait(false);
    }

    private static int ParsePageLimit(string? value) =>
        ParseBoundedInt(value, AiProtocol.DefaultPageSize, 1, AiProtocol.MaximumPageSize, "--limit");

    private static int ParseBoundedInt(
        string? value,
        int defaultValue,
        int minimum,
        int maximum,
        string option)
    {
        if (value is null)
        {
            return defaultValue;
        }

        if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int parsed) ||
            parsed < minimum || parsed > maximum)
        {
            throw Usage($"{option} must be between {minimum} and {maximum}.");
        }

        return parsed;
    }

    private static int MapExitCode(string code) => code switch
    {
        AiErrorCodes.AccessDenied or AiErrorCodes.ProtocolMismatch =>
            CliExitCodes.AccessOrProtocol,
        AiErrorCodes.ServiceUnavailable or AiErrorCodes.DriverUnavailable =>
            CliExitCodes.ServiceUnavailable,
        AiErrorCodes.CaptureConflict or AiErrorCodes.InvalidLease or
        AiErrorCodes.LeaseExpired or AiErrorCodes.StartReservationExpired =>
            CliExitCodes.ConflictOrLease,
        AiErrorCodes.DataGap or AiErrorCodes.IntegrityUnknown or
        AiErrorCodes.LegacyIntegrityUnknown or AiErrorCodes.ContinuityUnproven =>
            CliExitCodes.IntegrityOrData,
        AiErrorCodes.Timeout or AiErrorCodes.Cancelled =>
            CliExitCodes.TimeoutOrCancelled,
        _ => CliExitCodes.Unexpected,
    };

    private static void RequireOnlyFlags(
        IReadOnlyList<string> arguments,
        int start,
        params string[] flags)
    {
        HashSet<string> allowed = flags.ToHashSet(StringComparer.Ordinal);
        for (int index = start; index < arguments.Count; index++)
        {
            if (!allowed.Contains(arguments[index]))
            {
                throw Usage($"Unexpected argument '{arguments[index]}'.");
            }
        }
    }

    private static OptionSet ParseOptions(IReadOnlyList<string> arguments, int start) =>
        new(arguments.Skip(start));

    private static CliUsageException Usage(string message) => new(message);

    private sealed class CliUsageException(string message) : Exception(message);

    private sealed class OptionSet
    {
        private readonly Dictionary<string, List<string?>> _values =
            new(StringComparer.Ordinal);
        private readonly HashSet<string> _allowed = new(StringComparer.Ordinal);
        private readonly HashSet<string> _multiple = new(StringComparer.Ordinal);
        private readonly HashSet<string> _flagOptions = new(StringComparer.Ordinal);
        private readonly HashSet<string> _consumed = new(StringComparer.Ordinal);

        public OptionSet(IEnumerable<string> rawArguments)
        {
            string[] raw = rawArguments.ToArray();
            for (int index = 0; index < raw.Length; index++)
            {
                string name = raw[index];
                if (!name.StartsWith("--", StringComparison.Ordinal))
                {
                    throw Usage($"Unexpected argument '{name}'.");
                }

                string? value = null;
                if (index + 1 < raw.Length &&
                    !raw[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    value = raw[++index];
                }

                if (!_values.TryGetValue(name, out List<string?>? values))
                {
                    values = [];
                    _values.Add(name, values);
                }
                values.Add(value);
            }
        }

        public void Allow(string name, bool multiple = false)
        {
            _allowed.Add(name);
            if (multiple)
            {
                _multiple.Add(name);
            }
        }

        public void AllowFlag(string name)
        {
            _allowed.Add(name);
            _flagOptions.Add(name);
        }

        public void RequireFlag(string name)
        {
            AllowFlag(name);
            if (!ConsumeFlag(name))
            {
                throw Usage($"{name} is required.");
            }
        }

        public bool ConsumeFlag(string name)
        {
            AllowFlag(name);
            if (!_values.TryGetValue(name, out List<string?>? values))
            {
                _consumed.Add(name);
                return false;
            }

            if (values.Count != 1 || values[0] is not null)
            {
                throw Usage($"{name} is a flag and does not accept a value.");
            }
            _consumed.Add(name);
            return true;
        }

        public string RequireSingle(string name) =>
            OptionalSingle(name) ?? throw Usage($"{name} is required.");

        public string? OptionalSingle(string name)
        {
            Allow(name);
            _consumed.Add(name);
            if (!_values.TryGetValue(name, out List<string?>? values))
            {
                return null;
            }

            if (values.Count != 1 || string.IsNullOrWhiteSpace(values[0]))
            {
                throw Usage($"{name} requires exactly one non-empty value.");
            }

            return values[0];
        }

        public IReadOnlyList<string> RequireMany(string name) =>
            OptionalMany(name) is { Count: > 0 } values
                ? values
                : throw Usage($"At least one {name} value is required.");

        public IReadOnlyList<string>? OptionalMany(string name)
        {
            Allow(name, multiple: true);
            _consumed.Add(name);
            if (!_values.TryGetValue(name, out List<string?>? values))
            {
                return null;
            }

            if (values.Any(string.IsNullOrWhiteSpace))
            {
                throw Usage($"Every {name} occurrence requires a non-empty value.");
            }

            return values.Select(static value => value!).ToArray();
        }

        public void EnsureConsumed()
        {
            foreach ((string name, List<string?> values) in _values)
            {
                if (!_allowed.Contains(name))
                {
                    throw Usage($"Unknown option '{name}'.");
                }
                if (!_multiple.Contains(name) && values.Count > 1)
                {
                    throw Usage($"{name} may be specified only once.");
                }
                if (_flagOptions.Contains(name) && values.Any(static value => value is not null))
                {
                    throw Usage($"{name} is a flag and does not accept a value.");
                }
                if (!_consumed.Contains(name))
                {
                    throw Usage($"Option '{name}' is not valid in this context.");
                }
            }
        }
    }
}
