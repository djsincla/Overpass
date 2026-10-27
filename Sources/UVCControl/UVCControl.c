#include "UVCControl.h"
#include <stdlib.h>
#include <TargetConditionals.h>

#if TARGET_OS_OSX
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct UVCCamera {
    IOUSBDeviceInterface **device;
    int interface;
    int terminal, processing;
    uint32_t terminalControls, processingControls;
};

/// Bitmap of `size` bytes, little-endian.
static uint32_t bitmap(const uint8_t *p, int size) {
    uint32_t value = 0;
    for (int i = size - 1; i >= 0 && i < 4; i--) value = (value << 8) | p[i];
    return value;
}

/// Finds the video control interface, the camera terminal and the processing unit in the
/// configuration descriptor.
static void readDescriptors(UVCCamera *camera) {
    IOUSBConfigurationDescriptorPtr config;
    if ((*camera->device)->GetConfigurationDescriptorPtr(camera->device, 0, &config) != kIOReturnSuccess) return;
    const uint8_t *p = (const uint8_t *)config, *end = p + USBToHostWord(config->wTotalLength);
    int currentClass = 0, currentSubclass = 0;
    while (p + 2 <= end && p[0] > 0) {
        if (p[1] == 0x04 && p + 9 <= end) {  // interface
            currentClass = p[5];
            currentSubclass = p[6];
            if (currentClass == 14 && currentSubclass == 1) camera->interface = p[2];
        } else if (p[1] == 0x24 && currentClass == 14 && currentSubclass == 1 && p + 3 <= end) {
            if (p[2] == 0x02 && p + 15 <= end && (p[4] | p[5] << 8) == 0x0201) {  // camera input terminal
                camera->terminal = p[3];
                camera->terminalControls = bitmap(p + 15, p[14]);
            } else if (p[2] == 0x05 && p + 8 <= end) {  // processing unit
                camera->processing = p[3];
                camera->processingControls = bitmap(p + 8, p[7]);
            }
        }
        p += p[0];
    }
}

UVCCamera *uvc_open(uint32_t locationID, uint16_t vendor, uint16_t product) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int v = vendor, pr = product;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v), pn = CFNumberCreate(NULL, kCFNumberIntType, &pr);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), pn);
    CFRelease(vn);
    CFRelease(pn);
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) return NULL;
    io_service_t service, chosen = 0;
    while ((service = IOIteratorNext(iterator))) {
        uint32_t location = 0;
        CFTypeRef ref = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBDevicePropertyLocationID), NULL, 0);
        if (ref) {
            CFNumberGetValue(ref, kCFNumberSInt32Type, &location);
            CFRelease(ref);
        }
        if (!chosen && (locationID == 0 || location == locationID)) chosen = service;
        else IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (!chosen) return NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(chosen, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(chosen);
    if (kr != KERN_SUCCESS || !plugin) return NULL;
    IOUSBDeviceInterface **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
    IODestroyPlugInInterface(plugin);
    if (!device) return NULL;

    UVCCamera *camera = calloc(1, sizeof(UVCCamera));
    camera->device = device;
    readDescriptors(camera);
    if (!camera->terminal && !camera->processing) {
        uvc_close(camera);
        return NULL;
    }
    return camera;
}

void uvc_close(UVCCamera *camera) {
    if (!camera) return;
    if (camera->device) (*camera->device)->Release(camera->device);
    free(camera);
}

uint32_t uvc_controls(const UVCCamera *camera, UVCUnit unit) {
    return unit == UVCUnitTerminal ? camera->terminalControls : camera->processingControls;
}

static int request(const UVCCamera *camera, int in, int code, UVCUnit unit, int selector, int length, uint8_t *data) {
    int id = unit == UVCUnitTerminal ? camera->terminal : camera->processing;
    if (!id) return -1;
    IOUSBDevRequest r;
    r.bmRequestType = in ? 0xA1 : 0x21;  // class request to an interface
    r.bRequest = code;
    r.wValue = selector << 8;
    r.wIndex = (id << 8) | camera->interface;
    r.wLength = length;
    r.pData = data;
    r.wLenDone = 0;
    IOReturn result = (*camera->device)->DeviceRequest(camera->device, &r);
    return result == kIOReturnSuccess ? 0 : -(int)(result & 0xffff);
}

int uvc_get(const UVCCamera *camera, UVCGet code, UVCUnit unit, int selector, int length, uint32_t *value) {
    uint8_t data[4] = {0};
    int result = request(camera, 1, code, unit, selector, length, data);
    if (result == 0) *value = bitmap(data, length);
    return result;
}

int uvc_set(const UVCCamera *camera, UVCUnit unit, int selector, int length, uint32_t value) {
    uint8_t data[4] = {value & 255, (value >> 8) & 255, (value >> 16) & 255, (value >> 24) & 255};
    return request(camera, 0, 0x01, unit, selector, length, data);
}

#else

UVCCamera *uvc_open(uint32_t locationID, uint16_t vendor, uint16_t product) { return NULL; }
void uvc_close(UVCCamera *camera) {}
uint32_t uvc_controls(const UVCCamera *camera, UVCUnit unit) { return 0; }
int uvc_get(const UVCCamera *camera, UVCGet request, UVCUnit unit, int selector, int length, uint32_t *value) { return -1; }
int uvc_set(const UVCCamera *camera, UVCUnit unit, int selector, int length, uint32_t value) { return -1; }

#endif
