#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOUserClient.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>
#include <USBDriverKit/AppleUSBDescriptorParsing.h>
#include <USBDriverKit/USBDriverKitDefs.h>
#include <USBDriverKit/IOUSBHostFamilyDefinitions.h>

#include "OverpassSerial.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "OverpassSerial: " fmt, ##__VA_ARGS__)

static constexpr uint32_t kRingSize = 4096;
static constexpr uint32_t kTransferSize = 512;
static constexpr uint32_t kBaud = 115200;

struct OverpassSerial_IVars {
    IOUSBHostDevice *device;
    IOUSBHostInterface *interface;
    IOUSBHostPipe *in;
    IOUSBHostPipe *out;
    IOBufferMemoryDescriptor *inBuffer;
    IOBufferMemoryDescriptor *outBuffer;
    OSAction *readAction;
    IOLock *lock;
    uint8_t ring[kRingSize];
    uint32_t head;
    uint32_t count;
    bool stopping;
};

// The PL2303G (HXN) requests, as in Linux's drivers/usb/serial/pl2303.c.
enum : uint8_t {
    kVendorWrite = 0x40, kVendorRead = 0xC0, kClassOut = 0x21,
    kHXNWriteRequest = 0x80, kHXNReadRequest = 0x81,
    kSetLineCoding = 0x20, kSetControlLines = 0x22,
};
enum : uint16_t {
    kHXNResetRegister = 0x07, kHXNResetBothPipes = 0x03,
    kHXNFlowRegister = 0x0A, kHXNFlowMask = 0x1C, kHXNFlowNone = 0x1C,
    kDTRAndRTS = 0x03,
};

static kern_return_t Request(IOUSBHostInterface *interface, uint8_t type, uint8_t request,
                             uint16_t value, uint16_t index, const uint8_t *data, uint16_t length,
                             uint8_t *reply = nullptr)
{
    IOBufferMemoryDescriptor *buffer = nullptr;
    kern_return_t ret;
    if (length > 0) {
        // Both ways: a one-way buffer isn't writable (or readable) from the driver, which crashed it.
        ret = interface->CreateIOBuffer(kIOMemoryDirectionInOut, length, &buffer);
        if (ret != kIOReturnSuccess) return ret;
        IOAddressSegment range;
        buffer->GetAddressRange(&range);
        if (data) memcpy(reinterpret_cast<void *>(range.address), data, length);
        buffer->SetLength(length);
    }
    uint16_t transferred = 0;
    ret = interface->DeviceRequest(type, request, value, index, length, buffer, &transferred, 1000);
    if (ret == kIOReturnSuccess && reply && buffer) {
        IOAddressSegment range;
        buffer->GetAddressRange(&range);
        memcpy(reply, reinterpret_cast<const void *>(range.address), length);
    }
    OSSafeReleaseNULL(buffer);
    return ret;
}

/// Resets the chip's pipes, turns off flow control, sets 115200 8N1 and raises DTR and RTS.
static kern_return_t ConfigureLine(IOUSBHostInterface *interface)
{
    kern_return_t ret = Request(interface, kVendorWrite, kHXNWriteRequest, kHXNResetRegister, kHXNResetBothPipes, nullptr, 0);
    if (ret != kIOReturnSuccess) Log("reset failed 0x%x", ret);

    uint8_t flow = 0;
    if (Request(interface, kVendorRead, kHXNReadRequest, kHXNFlowRegister, 0, nullptr, 1, &flow) == kIOReturnSuccess) {
        flow = (flow & ~kHXNFlowMask) | kHXNFlowNone;
        Request(interface, kVendorWrite, kHXNWriteRequest, kHXNFlowRegister, flow, nullptr, 0);
    }

    // dwDTERate (little-endian), one stop bit, no parity, eight data bits.
    const uint8_t line[7] = { kBaud & 0xFF, (kBaud >> 8) & 0xFF, (kBaud >> 16) & 0xFF, (kBaud >> 24) & 0xFF, 0, 0, 8 };
    ret = Request(interface, kClassOut, kSetLineCoding, 0, 0, line, sizeof line);
    if (ret != kIOReturnSuccess) Log("line coding failed 0x%x", ret);

    ret = Request(interface, kClassOut, kSetControlLines, kDTRAndRTS, 0, nullptr, 0);
    if (ret != kIOReturnSuccess) Log("control lines failed 0x%x", ret);
    // Carry on regardless: the chip may already be set up, and the app reports what fails next.
    return kIOReturnSuccess;
}

bool OverpassSerial::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(OverpassSerial_IVars, 1);
    if (!ivars) return false;
    ivars->lock = IOLockAlloc();
    return ivars->lock != nullptr;
}

void OverpassSerial::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->readAction);
        OSSafeReleaseNULL(ivars->inBuffer);
        OSSafeReleaseNULL(ivars->outBuffer);
        OSSafeReleaseNULL(ivars->in);
        OSSafeReleaseNULL(ivars->out);
        OSSafeReleaseNULL(ivars->interface);
        OSSafeReleaseNULL(ivars->device);
        if (ivars->lock) IOLockFree(ivars->lock);
    }
    IOSafeDeleteNULL(ivars, OverpassSerial_IVars, 1);
    super::free();
}

kern_return_t IMPL(OverpassSerial, Start)
{
    Log("matched");
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    // iPadOS leaves an unknown vendor device unconfigured, so there's no interface to match:
    // match the device, select its configuration and take the interface from there.
    if (IOUSBHostDevice *device = OSDynamicCast(IOUSBHostDevice, provider)) {
        ivars->device = device;
        device->retain();
        ret = device->Open(this, 0, 0);
        if (ret != kIOReturnSuccess) { Log("device open failed 0x%x", ret); return ret; }
        ret = device->SetConfiguration(1, false);
        if (ret != kIOReturnSuccess) Log("set configuration failed 0x%x", ret);
        uintptr_t iterator = 0;
        ret = device->CreateInterfaceIterator(&iterator);
        if (ret != kIOReturnSuccess) { Log("no interface iterator 0x%x", ret); return ret; }
        device->CopyInterface(iterator, &ivars->interface);
        device->DestroyInterfaceIterator(iterator);
    } else if ((ivars->interface = OSDynamicCast(IOUSBHostInterface, provider))) {
        ivars->interface->retain();
    }
    if (!ivars->interface) { Log("no interface"); return kIOReturnNoDevice; }
    ret = ivars->interface->Open(this, 0, nullptr);
    if (ret != kIOReturnSuccess) { Log("open failed 0x%x", ret); return ret; }

    // The bulk endpoints, whatever their addresses.
    uint8_t inAddress = 0, outAddress = 0;
    const IOUSBConfigurationDescriptor *config = ivars->interface->CopyConfigurationDescriptor();
    if (config) {
        const IOUSBInterfaceDescriptor *descriptor = ivars->interface->GetInterfaceDescriptor(config);
        const IOUSBEndpointDescriptor *endpoint = nullptr;
        while (descriptor && (endpoint = IOUSBGetNextEndpointDescriptor(config, descriptor,
                                                                        reinterpret_cast<const IOUSBDescriptorHeader *>(endpoint)))) {
            if (IOUSBGetEndpointType(endpoint) != kIOUSBEndpointTypeBulk) continue;
            if (IOUSBGetEndpointDirection(endpoint) == kIOUSBEndpointDirectionIn) inAddress = IOUSBGetEndpointAddress(endpoint);
            else outAddress = IOUSBGetEndpointAddress(endpoint);
        }
        IOUSBHostFreeDescriptor(config);
    }
    if (!inAddress || !outAddress) { Log("no bulk endpoints"); return kIOReturnNoDevice; }

    ret = ivars->interface->CopyPipe(inAddress, &ivars->in);
    if (ret == kIOReturnSuccess) ret = ivars->interface->CopyPipe(outAddress, &ivars->out);
    if (ret == kIOReturnSuccess) ret = ivars->interface->CreateIOBuffer(kIOMemoryDirectionIn, kTransferSize, &ivars->inBuffer);
    if (ret == kIOReturnSuccess) ret = ivars->interface->CreateIOBuffer(kIOMemoryDirectionInOut, kTransferSize, &ivars->outBuffer);
    if (ret == kIOReturnSuccess) ret = ConfigureLine(ivars->interface);
    if (ret == kIOReturnSuccess) ret = CreateActionReadComplete(0, &ivars->readAction);
    if (ret == kIOReturnSuccess) ret = ivars->in->AsyncIO(ivars->inBuffer, kTransferSize, ivars->readAction, 0);
    if (ret != kIOReturnSuccess) { Log("start failed 0x%x", ret); return ret; }

    Log("ready");
    return RegisterService();
}

kern_return_t IMPL(OverpassSerial, Stop)
{
    ivars->stopping = true;
    if (ivars->in) ivars->in->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->out) ivars->out->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->interface) ivars->interface->Close(this, 0);
    if (ivars->device) ivars->device->Close(this, 0);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(OverpassSerial, NewUserClient)
{
    IOService *client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) return ret;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

void IMPL(OverpassSerial, ReadComplete)
{
    if (status == kIOReturnSuccess && actualByteCount > 0) {
        IOAddressSegment range;
        ivars->inBuffer->GetAddressRange(&range);
        const uint8_t *bytes = reinterpret_cast<const uint8_t *>(range.address);
        IOLockLock(ivars->lock);
        for (uint32_t i = 0; i < actualByteCount; i++) {
            // When full, the oldest byte goes: the app only ever wants the latest reply.
            ivars->ring[(ivars->head + ivars->count) % kRingSize] = bytes[i];
            if (ivars->count < kRingSize) ivars->count++;
            else ivars->head = (ivars->head + 1) % kRingSize;
        }
        IOLockUnlock(ivars->lock);
    }
    if (ivars->stopping || status == kIOReturnAborted || status == kIOReturnNoDevice || status == kIOReturnOffline) return;
    if (status == kUSBHostReturnPipeStalled) ivars->in->ClearStall(true);
    kern_return_t ret = ivars->in->AsyncIO(ivars->inBuffer, kTransferSize, ivars->readAction, 0);
    if (ret != kIOReturnSuccess) Log("read resubmit failed 0x%x", ret);
}

kern_return_t OverpassSerial::Send(const uint8_t *bytes, uint32_t length)
{
    if (ivars->stopping || !ivars->out) return kIOReturnNoDevice;
    IOAddressSegment range;
    ivars->outBuffer->GetAddressRange(&range);
    while (length > 0) {
        uint32_t chunk = length < kTransferSize ? length : kTransferSize;
        memcpy(reinterpret_cast<void *>(range.address), bytes, chunk);
        ivars->outBuffer->SetLength(chunk);
        uint32_t sent = 0;
        kern_return_t ret = ivars->out->IO(ivars->outBuffer, chunk, &sent, 1000);
        if (ret != kIOReturnSuccess) return ret;
        bytes += chunk;
        length -= chunk;
    }
    return kIOReturnSuccess;
}

uint32_t OverpassSerial::Receive(uint8_t *bytes, uint32_t capacity)
{
    IOLockLock(ivars->lock);
    uint32_t n = ivars->count < capacity ? ivars->count : capacity;
    for (uint32_t i = 0; i < n; i++) bytes[i] = ivars->ring[(ivars->head + i) % kRingSize];
    ivars->head = (ivars->head + n) % kRingSize;
    ivars->count -= n;
    IOLockUnlock(ivars->lock);
    return n;
}

void OverpassSerial::Discard()
{
    IOLockLock(ivars->lock);
    ivars->head = 0;
    ivars->count = 0;
    IOLockUnlock(ivars->lock);
}
