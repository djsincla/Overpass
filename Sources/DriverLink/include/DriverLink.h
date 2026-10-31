#ifndef DRIVERLINK_H
#define DRIVERLINK_H

#include <stdint.h>

/// The app's side of Overpass's own USB serial driver (Driver/OverpassSerial), which runs the
/// mount's PL2303G adapter on an iPad. iPadOS only; elsewhere driverlink_open returns NULL.
typedef struct DriverLink DriverLink;

/// Selectors shared with OverpassSerialUserClient.
enum { DriverLinkSend = 0, DriverLinkReceive = 1, DriverLinkDiscard = 2 };
#define DriverLinkMaxReceive 1024

/// Whether the driver is running: the adapter is plugged in and the driver is switched on.
int driverlink_available(void);

/// What the USB system shows: each device's IDs and name, and what has claimed its interfaces.
/// Writes a line per device into `text` (NUL-terminated) for diagnosing a driver that doesn't load.
void driverlink_describe_usb(char *text, uint32_t capacity);

/// A connection to the driver, or NULL.
DriverLink *driverlink_open(void);
void driverlink_close(DriverLink *link);

/// Returns 0, or a negative IOKit error.
int driverlink_send(DriverLink *link, const uint8_t *bytes, uint32_t length);

/// Moves up to `capacity` received bytes into `bytes`. Returns how many, or a negative IOKit error.
int driverlink_receive(DriverLink *link, uint8_t *bytes, uint32_t capacity);

/// Drops anything received and not yet read. Returns 0, or a negative IOKit error.
int driverlink_discard(DriverLink *link);

#endif
