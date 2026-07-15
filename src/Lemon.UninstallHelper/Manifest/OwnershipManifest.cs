namespace Lemon.UninstallHelper.Manifest;

public enum OwnedObjectKind
{
    ImmutableFile,
    DynamicFile,
    Directory,
}

public enum ApprovedRootRole
{
    AppRoot,
    AiStateRoot,
}

public sealed record OwnedObject(
    string ObjectId,
    string RelativePath,
    OwnedObjectKind Kind,
    long? Size,
    string? Sha256,
    string? ProductMarker,
    ulong? VolumeSerialNumber,
    string? FileId)
{
    public static OwnedObject ImmutableFile(
        string objectId,
        string relativePath,
        long size,
        string sha256,
        string productMarker) =>
        new(
            objectId,
            relativePath,
            OwnedObjectKind.ImmutableFile,
            size,
            sha256,
            productMarker,
            null,
            null);

    public static OwnedObject DynamicFile(
        string objectId,
        string relativePath,
        ulong volumeSerialNumber,
        string fileId) =>
        new(
            objectId,
            relativePath,
            OwnedObjectKind.DynamicFile,
            null,
            null,
            null,
            volumeSerialNumber,
            fileId);

    public static OwnedObject Directory(string objectId, string relativePath) =>
        new(objectId, relativePath, OwnedObjectKind.Directory, null, null, null, null, null);
}

public sealed record ApprovedRootManifest(
    string CanonicalPath,
    ulong VolumeSerialNumber,
    string FileId,
    IReadOnlyList<OwnedObject> Objects,
    ApprovedRootRole Role = ApprovedRootRole.AppRoot);
