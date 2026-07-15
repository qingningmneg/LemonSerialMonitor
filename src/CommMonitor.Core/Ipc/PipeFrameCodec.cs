namespace CommMonitor.Core.Ipc;

public static class PipeFrameCodec
{
    private static readonly JsonFrameOptions FrameOptions =
        new(PipeProtocol.MaximumFrameLength, MaximumDepth: 64);

    public static ValueTask<T> ReadAsync<T>(
        Stream stream,
        CancellationToken cancellationToken = default) =>
        LengthPrefixedJsonCodec.ReadAsync<T>(stream, FrameOptions, cancellationToken);

    public static ValueTask WriteAsync<T>(
        Stream stream,
        T value,
        CancellationToken cancellationToken = default) =>
        LengthPrefixedJsonCodec.WriteAsync(stream, value, FrameOptions, cancellationToken);
}
