namespace CommMonitor.Core.Copying;

public enum CopyFormat
{
    HexSpaced,
    HexCompact,
    Text,
    CArray,
    PythonBytes,
    Tsv,
    Csv,
    Json,
}

public sealed record CopyOptions(
    CopyFormat Format,
    bool IncludeSequence,
    bool IncludeTimestamp,
    bool IncludePort,
    bool IncludeDirection,
    bool IncludeProcess);
