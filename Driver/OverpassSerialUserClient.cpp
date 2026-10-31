#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSData.h>

#include "OverpassSerial.h"
#include "OverpassSerialUserClient.h"
#include "../Sources/DriverLink/include/DriverLink.h"

struct OverpassSerialUserClient_IVars {
    OverpassSerial *driver;
};

bool OverpassSerialUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(OverpassSerialUserClient_IVars, 1);
    return ivars != nullptr;
}

void OverpassSerialUserClient::free()
{
    if (ivars) OSSafeReleaseNULL(ivars->driver);
    IOSafeDeleteNULL(ivars, OverpassSerialUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(OverpassSerialUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->driver = OSDynamicCast(OverpassSerial, provider);
    if (!ivars->driver) return kIOReturnNoDevice;
    ivars->driver->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(OverpassSerialUserClient, Stop)
{
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t OverpassSerialUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *arguments,
                                                       const IOUserClientMethodDispatch *, OSObject *, void *)
{
    OverpassSerial *driver = ivars->driver;
    if (!driver) return kIOReturnNotAttached;

    switch (selector) {
    case DriverLinkSend: {
        OSData *input = arguments->structureInput;
        if (!input) return kIOReturnBadArgument;
        return driver->Send(static_cast<const uint8_t *>(input->getBytesNoCopy()), static_cast<uint32_t>(input->getLength()));
    }
    case DriverLinkReceive: {
        uint8_t bytes[DriverLinkMaxReceive];
        uint32_t n = driver->Receive(bytes, sizeof bytes);
        arguments->structureOutput = OSData::withBytes(bytes, n);
        return arguments->structureOutput ? kIOReturnSuccess : kIOReturnNoMemory;
    }
    case DriverLinkDiscard:
        driver->Discard();
        return kIOReturnSuccess;
    default:
        return kIOReturnBadArgument;
    }
}
