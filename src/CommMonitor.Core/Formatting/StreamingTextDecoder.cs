using System.Text;

namespace CommMonitor.Core.Formatting;

public sealed class StreamingTextDecoder
{
    private readonly Encoding _encoding;
    private readonly Decoder _decoder;

    public StreamingTextDecoder(Encoding encoding)
    {
        _encoding = encoding ?? throw new ArgumentNullException(nameof(encoding));
        _decoder = encoding.GetDecoder();
    }

    public string Decode(ReadOnlySpan<byte> bytes)
    {
        char[] characters = new char[_encoding.GetMaxCharCount(bytes.Length)];
        _decoder.Convert(
            bytes,
            characters,
            flush: false,
            out int bytesUsed,
            out int charactersUsed,
            out bool completed);

        if (!completed || bytesUsed != bytes.Length)
        {
            throw new InvalidOperationException("The decoder output buffer was unexpectedly too small.");
        }

        return new string(characters, 0, charactersUsed);
    }

    public void Reset() => _decoder.Reset();
}
