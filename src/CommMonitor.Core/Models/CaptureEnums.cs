namespace CommMonitor.Core.Models;

public enum CaptureKind : uint { Read = 1, Write = 2, Ioctl = 3, Create = 4, Close = 5, DropNotice = 6, DeviceArrival = 7, DeviceRemoval = 8 }
public enum CaptureState : uint { Stopped = 0, Running = 1, Paused = 2 }
[Flags]
public enum CaptureFlags : uint { None = 0, Truncated = 1, InputPayload = 2, OutputPayload = 4, Synthetic = 8 }
