using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Ipc;

namespace CommMonitor.Service.Tests.Ipc;

public sealed class PipeFrameCodecTests
{
    private static readonly JsonFrameOptions AiFrameOptions =
        new(AiProtocol.MaximumResponseBytes, MaximumDepth: 64);

    [Fact]
    public async Task ReadAsync_reassembles_one_byte_reads_and_deserializes_start_command()
    {
        string json =
            """
            {"version":1,"requestId":"start-42","command":"Start","deviceIds":[17,99],"sessionPath":"capture.db"}
            """.Replace(
                "\"version\":1",
                $"\"version\":{PipeProtocol.Version}",
                StringComparison.Ordinal);
        await using var stream = new OneByteReadStream(CreateFrame(json));

        PipeCommand command = await PipeFrameCodec.ReadAsync<PipeCommand>(stream);

        Assert.Equal(PipeProtocol.Version, command.Version);
        Assert.Equal("start-42", command.RequestId);
        Assert.Equal(PipeCommandName.Start, command.Command);
        Assert.Equal(new ulong[] { 17, 99 }, command.DeviceIds);
        Assert.Equal("capture.db", command.SessionPath);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(0)]
    [InlineData(PipeProtocol.MaximumFrameLength + 1)]
    public async Task ReadAsync_rejects_invalid_lengths_before_reading_a_payload(int length)
    {
        byte[] prefix = new byte[sizeof(int)];
        BinaryPrimitives.WriteInt32LittleEndian(prefix, length);
        await using var stream = new MemoryStream(prefix);

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await PipeFrameCodec.ReadAsync<PipeCommand>(stream));

        Assert.Equal(sizeof(int), stream.Position);
    }

    [Fact]
    public async Task ReadAsync_rejects_malformed_json()
    {
        await using var stream = new MemoryStream(CreateFrame("{not-json}"));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await PipeFrameCodec.ReadAsync<PipeCommand>(stream));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public async Task ReadAsync_rejects_a_command_without_a_nonempty_request_id(string requestId)
    {
        string json = JsonSerializer.Serialize(new
        {
            version = PipeProtocol.Version,
            requestId,
            command = "Stop",
        });
        await using var stream = new MemoryStream(CreateFrame(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await PipeFrameCodec.ReadAsync<PipeCommand>(stream));
    }

    [Fact]
    public async Task ReadAsync_rejects_a_request_with_missing_request_id()
    {
        await using var stream = new MemoryStream(CreateFrame(
            """
            {"version":1,"command":"Stop"}
            """));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await PipeFrameCodec.ReadAsync<PipeCommand>(stream));
    }

    [Fact]
    public async Task ReadAsync_rejects_a_request_with_missing_command()
    {
        await using var stream = new MemoryStream(CreateFrame(
            """
            {"version":1,"requestId":"missing-command"}
            """));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await PipeFrameCodec.ReadAsync<PipeCommand>(stream));
    }

    [Fact]
    public async Task WriteAsync_uses_a_little_endian_length_camel_case_and_string_enums()
    {
        var command = new PipeCommand("pause-7", PipeCommandName.Pause);
        await using var stream = new MemoryStream();

        await PipeFrameCodec.WriteAsync(stream, command);

        byte[] frame = stream.ToArray();
        int payloadLength = BinaryPrimitives.ReadInt32LittleEndian(frame);
        Assert.Equal(frame.Length - sizeof(int), payloadLength);
        using JsonDocument document = JsonDocument.Parse(frame.AsMemory(sizeof(int), payloadLength));
        JsonElement root = document.RootElement;
        Assert.Equal(PipeProtocol.Version, root.GetProperty("version").GetInt32());
        Assert.Equal("pause-7", root.GetProperty("requestId").GetString());
        Assert.Equal("Pause", root.GetProperty("command").GetString());
        Assert.False(root.TryGetProperty("RequestId", out _));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_an_oversized_frame_before_reading_the_payload()
    {
        await using var stream = new PayloadReadCountingStream(
            AiProtocol.MaximumResponseBytes + 1);

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));

        Assert.Equal(0, stream.PayloadReadCount);
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_a_truncated_length_prefix()
    {
        await using var stream = new MemoryStream([0x01, 0x00, 0x00]);

        await Assert.ThrowsAsync<EndOfStreamException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_a_truncated_payload()
    {
        byte[] frame = new byte[sizeof(int) + 2];
        BinaryPrimitives.WriteInt32LittleEndian(frame, 3);
        frame[^2] = (byte)'{';
        frame[^1] = (byte)'}';
        await using var stream = new MemoryStream(frame);

        await Assert.ThrowsAsync<EndOfStreamException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_JSON_null()
    {
        await using var stream = new MemoryStream(CreateFrame("null"));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_depth_65()
    {
        string json = new string('[', 65) + "0" + new string(']', 65);
        await using var stream = new MemoryStream(CreateFrame(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<JsonElement>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_malformed_JSON()
    {
        await using var stream = new MemoryStream(CreateFrame("{not-json}"));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_invalid_UTF8()
    {
        byte[] frame = new byte[sizeof(int) + 1];
        BinaryPrimitives.WriteInt32LittleEndian(frame, 1);
        frame[^1] = 0xFF;
        await using var stream = new MemoryStream(frame);

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_unmapped_members()
    {
        const string json =
            """
            {"version":1,"requestId":"strict-1","command":"Stop","unexpected":true}
            """;
        await using var stream = new MemoryStream(CreateFrame(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_rejects_integer_enum_values()
    {
        const string json =
            """
            {"version":1,"requestId":"strict-2","command":5}
            """;
        await using var stream = new MemoryStream(CreateFrame(json));

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions));
    }

    [Fact]
    public async Task Generic_ReadAsync_observes_cancellation()
    {
        await using var stream = new MemoryStream(CreateFrame("{}"));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            async () => await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
                stream,
                AiFrameOptions,
                cancellation.Token));
    }

    [Fact]
    public async Task Generic_codec_round_trips_a_valid_frame()
    {
        var expected = new PipeCommand(
            "start-99",
            PipeCommandName.Start,
            deviceIds: [17, 99],
            sessionPath: "capture.db");
        await using var frame = new MemoryStream();

        await LengthPrefixedJsonCodec.WriteAsync(frame, expected, AiFrameOptions);
        frame.Position = 0;
        PipeCommand actual = await LengthPrefixedJsonCodec.ReadAsync<PipeCommand>(
            frame,
            AiFrameOptions);

        Assert.Equal(expected.Version, actual.Version);
        Assert.Equal(expected.RequestId, actual.RequestId);
        Assert.Equal(expected.Command, actual.Command);
        Assert.Equal(expected.DeviceIds, actual.DeviceIds);
        Assert.Equal(expected.SessionPath, actual.SessionPath);
    }

    [Fact]
    public async Task Generic_WriteAsync_rejects_an_oversized_payload_before_writing_any_bytes()
    {
        var options = new JsonFrameOptions(MaximumFrameLength: 5, MaximumDepth: 64);
        await using var stream = new MemoryStream();

        await Assert.ThrowsAsync<InvalidDataException>(
            async () => await LengthPrefixedJsonCodec.WriteAsync(
                stream,
                "1234",
                options));

        Assert.Equal(0, stream.Length);
    }

    [Fact]
    public async Task Generic_codec_accepts_a_payload_exactly_at_the_maximum_length()
    {
        var options = new JsonFrameOptions(MaximumFrameLength: 6, MaximumDepth: 64);
        await using var stream = new MemoryStream();

        await LengthPrefixedJsonCodec.WriteAsync(stream, "1234", options);

        byte[] frame = stream.ToArray();
        Assert.Equal(6, BinaryPrimitives.ReadInt32LittleEndian(frame));
        Assert.Equal(sizeof(int) + 6, frame.Length);
        stream.Position = 0;
        Assert.Equal(
            "1234",
            await LengthPrefixedJsonCodec.ReadAsync<string>(stream, options));
    }

    private static byte[] CreateFrame(string json)
    {
        byte[] payload = Encoding.UTF8.GetBytes(json);
        byte[] frame = new byte[sizeof(int) + payload.Length];
        BinaryPrimitives.WriteInt32LittleEndian(frame, payload.Length);
        payload.CopyTo(frame, sizeof(int));
        return frame;
    }

    private sealed class OneByteReadStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override int Read(byte[] buffer, int offset, int count) =>
            base.Read(buffer, offset, Math.Min(count, 1));

        public override int Read(Span<byte> buffer) =>
            base.Read(buffer[..Math.Min(buffer.Length, 1)]);

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default) =>
            base.ReadAsync(buffer[..Math.Min(buffer.Length, 1)], cancellationToken);
    }

    private sealed class PayloadReadCountingStream(int length) : Stream
    {
        private readonly byte[] _prefix = CreatePrefix(length);
        private int _prefixOffset;

        public int PayloadReadCount { get; private set; }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            Read(buffer.AsSpan(offset, count));

        public override int Read(Span<byte> buffer)
        {
            if (_prefixOffset < _prefix.Length)
            {
                int count = Math.Min(buffer.Length, _prefix.Length - _prefixOffset);
                _prefix.AsSpan(_prefixOffset, count).CopyTo(buffer);
                _prefixOffset += count;
                return count;
            }

            PayloadReadCount++;
            return 0;
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(Read(buffer.Span));
        }

        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        private static byte[] CreatePrefix(int length)
        {
            byte[] prefix = new byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(prefix, length);
            return prefix;
        }
    }
}
