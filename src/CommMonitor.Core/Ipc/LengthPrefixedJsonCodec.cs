using System.Buffers;
using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Ai;

namespace CommMonitor.Core.Ipc;

public sealed record JsonFrameOptions(
    int MaximumFrameLength,
    int MaximumDepth);

public static class LengthPrefixedJsonCodec
{
    private const int LengthPrefixSize = sizeof(int);

    private static readonly UTF8Encoding StrictUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static async ValueTask<T> ReadAsync<T>(
        Stream stream,
        JsonFrameOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ValidateOptions(options);

        byte[] lengthPrefix = new byte[LengthPrefixSize];
        await ReadExactlyAsync(stream, lengthPrefix, cancellationToken).ConfigureAwait(false);

        int length = BinaryPrimitives.ReadInt32LittleEndian(lengthPrefix);
        if (length is <= 0 || length > options.MaximumFrameLength)
        {
            throw new InvalidDataException(
                $"Frame length must be between 1 and {options.MaximumFrameLength} bytes.");
        }

        byte[] payload = ArrayPool<byte>.Shared.Rent(length);
        try
        {
            await ReadExactlyAsync(
                    stream,
                    payload.AsMemory(0, length),
                    cancellationToken)
                .ConfigureAwait(false);

            return Deserialize<T>(payload.AsSpan(0, length), options.MaximumDepth);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(payload, clearArray: true);
        }
    }

    public static async ValueTask WriteAsync<T>(
        Stream stream,
        T value,
        JsonFrameOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(stream);
        ArgumentNullException.ThrowIfNull(value);
        ValidateOptions(options);

        JsonSerializerOptions serializerOptions = CreateSerializerOptions(options.MaximumDepth);
        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(value, serializerOptions);
        if (payload.Length is <= 0 || payload.Length > options.MaximumFrameLength)
        {
            throw new InvalidDataException(
                $"Frame length must be between 1 and {options.MaximumFrameLength} bytes.");
        }

        byte[] lengthPrefix = new byte[LengthPrefixSize];
        BinaryPrimitives.WriteInt32LittleEndian(lengthPrefix, payload.Length);

        await stream.WriteAsync(lengthPrefix, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static T Deserialize<T>(ReadOnlySpan<byte> payload, int maximumDepth)
    {
        try
        {
            string json = StrictUtf8.GetString(payload);
            using JsonDocument document = JsonDocument.Parse(
                json,
                new JsonDocumentOptions { MaxDepth = maximumDepth });
            if (document.RootElement.ValueKind == JsonValueKind.Null)
            {
                throw new InvalidDataException("A JSON frame cannot contain null.");
            }

            T? value = document.RootElement.Deserialize<T>(CreateSerializerOptions(maximumDepth));
            return value is null
                ? throw new InvalidDataException("A JSON frame cannot contain null.")
                : value;
        }
        catch (Exception exception) when (
            exception is DecoderFallbackException or
            JsonException or
            NotSupportedException or
            ArgumentException)
        {
            throw new InvalidDataException(
                "The frame does not contain a valid JSON document.",
                exception);
        }
    }

    private static JsonSerializerOptions CreateSerializerOptions(int maximumDepth)
    {
        JsonSerializerOptions options = AiJson.CreateOptions();
        options.MaxDepth = maximumDepth;
        return options;
    }

    private static async ValueTask ReadExactlyAsync(
        Stream stream,
        Memory<byte> destination,
        CancellationToken cancellationToken)
    {
        int read = 0;
        while (read < destination.Length)
        {
            int count = await stream
                .ReadAsync(destination[read..], cancellationToken)
                .ConfigureAwait(false);
            if (count == 0)
            {
                throw new EndOfStreamException("The stream ended before the frame was complete.");
            }

            read += count;
        }
    }

    private static void ValidateOptions(JsonFrameOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.MaximumFrameLength <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The maximum frame length must be positive.");
        }

        if (options.MaximumDepth <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "The maximum JSON depth must be positive.");
        }
    }
}
