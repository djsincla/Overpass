#include "DriverLink.h"
#include <stdlib.h>
#include <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

struct DriverLink {
    io_connect_t connection;
};

/// The driver's service, by its class name, or 0.
static io_service_t findService(void) {
    return IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("OverpassSerial"));
}

int driverlink_available(void) {
    io_service_t service = findService();
    if (!service) return 0;
    IOObjectRelease(service);
    return 1;
}

static int numberProperty(io_registry_entry_t entry, CFStringRef key) {
    int value = -1;
    CFTypeRef ref = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue(ref, kCFNumberIntType, &value);
    if (ref) CFRelease(ref);
    return value;
}

static void append(char *text, uint32_t capacity, const char *line) {
    size_t used = strlen(text);
    if (used + 1 < capacity) snprintf(text + used, capacity - used, "%s", line);
}

/// Every descendant's class, to see which driver (if any) took the interface.
static void describeChildren(io_registry_entry_t entry, int depth, char *text, uint32_t capacity) {
    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) != KERN_SUCCESS) return;
    io_registry_entry_t child;
    while ((child = IOIteratorNext(children))) {
        io_name_t cls = "", name = "";
        IOObjectGetClass(child, cls);
        IORegistryEntryGetName(child, name);
        char line[200];
        snprintf(line, sizeof line, "%*s%s (%s)\n", depth * 2, "", name, cls);
        append(text, capacity, line);
        if (depth < 4) describeChildren(child, depth + 1, text, capacity);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
}

void driverlink_describe_usb(char *text, uint32_t capacity) {
    if (capacity == 0) return;
    text[0] = 0;
    io_iterator_t devices = 0;
    kern_return_t ret = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices);
    if (ret != KERN_SUCCESS) {
        char line[80];
        snprintf(line, sizeof line, "Can't list USB devices: 0x%x\n", ret);
        append(text, capacity, line);
        return;
    }
    int count = 0;
    io_service_t device;
    while ((device = IOIteratorNext(devices))) {
        io_name_t name = "";
        IORegistryEntryGetName(device, name);
        char line[200];
        snprintf(line, sizeof line, "%04X:%04X %s\n", numberProperty(device, CFSTR("idVendor")) & 0xFFFF,
                 numberProperty(device, CFSTR("idProduct")) & 0xFFFF, name);
        append(text, capacity, line);
        describeChildren(device, 1, text, capacity);
        IOObjectRelease(device);
        count++;
    }
    IOObjectRelease(devices);
    if (count == 0) append(text, capacity, "No USB devices visible.\n");
}

DriverLink *driverlink_open(void) {
    io_service_t service = findService();
    if (!service) return NULL;
    io_connect_t connection = 0;
    kern_return_t ret = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (ret != KERN_SUCCESS) return NULL;
    DriverLink *link = calloc(1, sizeof *link);
    if (!link) { IOServiceClose(connection); return NULL; }
    link->connection = connection;
    return link;
}

void driverlink_close(DriverLink *link) {
    if (!link) return;
    IOServiceClose(link->connection);
    free(link);
}

int driverlink_send(DriverLink *link, const uint8_t *bytes, uint32_t length) {
    kern_return_t ret = IOConnectCallStructMethod(link->connection, DriverLinkSend, bytes, length, NULL, NULL);
    return ret == KERN_SUCCESS ? 0 : -(int)(ret & 0x3fff) - 1;
}

int driverlink_receive(DriverLink *link, uint8_t *bytes, uint32_t capacity) {
    uint8_t buffer[DriverLinkMaxReceive];
    size_t size = sizeof buffer;
    kern_return_t ret = IOConnectCallStructMethod(link->connection, DriverLinkReceive, NULL, 0, buffer, &size);
    if (ret != KERN_SUCCESS) return -(int)(ret & 0x3fff) - 1;
    if (size > capacity) size = capacity;
    for (size_t i = 0; i < size; i++) bytes[i] = buffer[i];
    return (int)size;
}

int driverlink_discard(DriverLink *link) {
    kern_return_t ret = IOConnectCallScalarMethod(link->connection, DriverLinkDiscard, NULL, 0, NULL, NULL);
    return ret == KERN_SUCCESS ? 0 : -(int)(ret & 0x3fff) - 1;
}

#else

int driverlink_available(void) { return 0; }
void driverlink_describe_usb(char *text, uint32_t capacity) { if (capacity) text[0] = 0; }
DriverLink *driverlink_open(void) { return NULL; }
void driverlink_close(DriverLink *link) { (void)link; }
int driverlink_send(DriverLink *link, const uint8_t *bytes, uint32_t length) { (void)link; (void)bytes; (void)length; return -1; }
int driverlink_receive(DriverLink *link, uint8_t *bytes, uint32_t capacity) { (void)link; (void)bytes; (void)capacity; return -1; }
int driverlink_discard(DriverLink *link) { (void)link; return -1; }

#endif
