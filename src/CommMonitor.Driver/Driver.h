#pragma once

#include <ntifs.h>
#include <wdf.h>

#include "CaptureCore.h"
#include "TransportCore.h"

#define CMON_RING_CAPACITY 2048u
#define CMON_POOL_TAG ((ULONG)'noMC')

typedef enum _CMON_CONTROL_STATE
{
    CmonControlAbsent = 0,
    CmonControlActive = 1,
    CmonControlDeleting = 2,
} CMON_CONTROL_STATE;

typedef struct _DEVICE_CONTEXT
{
    WDFDEVICE Device;
    WDFDRIVER Driver;
    ULONGLONG DeviceIdHash;
    LIST_ENTRY ActiveListEntry;
    EX_RUNDOWN_REF RecreateWorkRundown;
    BOOLEAN Registered;
} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, CmonGetDeviceContext);

typedef struct _REQUEST_CONTEXT
{
    WDFDEVICE Device;
    WDFMEMORY EventMemory;
    CMON_CAPTURE_METADATA Metadata;
    CMON_CAPTURE_DIRECTION Direction;
    ULONG SnapshotLength;
    ULONG SnapshotFlags;
} REQUEST_CONTEXT, *PREQUEST_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(REQUEST_CONTEXT, CmonGetRequestContext);

typedef struct _CONTROL_DEVICE_CONTEXT
{
    WDFDRIVER Driver;
    BOOLEAN Published;
} CONTROL_DEVICE_CONTEXT, *PCONTROL_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(
    CONTROL_DEVICE_CONTEXT,
    CmonGetControlDeviceContext);

typedef struct _DRIVER_CONTEXT
{
    CMON_RING_CORE Ring;
    WDFSPINLOCK SpinLock;
    WDFWAITLOCK LifecycleLock;
    LIST_ENTRY ActivePnpList;
    WDFDEVICE ControlDevice;
    ULONG PnpDeviceCount;
    CMON_CONTROL_STATE ControlState;
    BOOLEAN RecreateAfterDelete;
    BOOLEAN RecreateWorkerQueued;
    ULONG CaptureState;
    ULONG SelectedDeviceCount;
    ULONGLONG SelectedDeviceHashes[CMON_MAX_SELECTED_DEVICES];
} DRIVER_CONTEXT, *PDRIVER_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DRIVER_CONTEXT, CmonGetDriverContext);

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD CommMonitorEvtDeviceAdd;
EVT_WDF_DEVICE_CONTEXT_CLEANUP CmonEvtDeviceContextCleanup;
EVT_WDF_DEVICE_CONTEXT_DESTROY CmonEvtControlDeviceDestroy;
EVT_WDF_OBJECT_CONTEXT_CLEANUP CmonDriverContextCleanup;
EVT_WDF_IO_QUEUE_IO_DEFAULT CommMonitorEvtIoDefault;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL CmonEvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_READ CmonEvtIoRead;
EVT_WDF_IO_QUEUE_IO_WRITE CmonEvtIoWrite;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL CmonEvtIoSerialDeviceControl;
EVT_WDF_REQUEST_COMPLETION_ROUTINE CmonEvtCaptureRequestCompletion;
IO_WORKITEM_ROUTINE_EX CmonRecreateControlWorkItem;

NTSTATUS
CmonCreateControlDevice(
    _In_ WDFDRIVER Driver);

VOID
CmonRegisterPnpDevice(
    _In_ WDFDEVICE Device);

VOID
CmonUnregisterPnpDevice(
    _In_ WDFDEVICE Device);

NTSTATUS
CmonRingPush(
    _Inout_ PDRIVER_CONTEXT Context,
    _In_ const CMON_EVENT_SLOT* Event);

NTSTATUS
CmonRingPopBatch(
    _Inout_ PDRIVER_CONTEXT Context,
    _Out_writes_bytes_to_(OutputBufferLength, *BytesWritten) PVOID OutputBuffer,
    _In_ SIZE_T OutputBufferLength,
    _Out_ PULONG_PTR BytesWritten);
