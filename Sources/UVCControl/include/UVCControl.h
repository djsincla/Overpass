#ifndef UVCCONTROL_H
#define UVCCONTROL_H

#include <stdint.h>

/// Standard USB Video Class requests to a camera, for the controls AVFoundation doesn't expose
/// on a Mac (manual exposure, gain). macOS only; elsewhere uvc_open returns NULL.
typedef struct UVCCamera UVCCamera;

/// The camera terminal (exposure) or the processing unit (gain, brightness and so on).
typedef enum { UVCUnitTerminal = 0, UVCUnitProcessing = 1 } UVCUnit;

/// GET_CUR, GET_MIN, GET_MAX, GET_RES, GET_DEF.
typedef enum { UVCGetCurrent = 0x81, UVCGetMinimum = 0x82, UVCGetMaximum = 0x83,
               UVCGetResolution = 0x84, UVCGetDefault = 0x87 } UVCGet;

/// The camera at `locationID` (0 for the first match) with this vendor and product, or NULL.
UVCCamera *uvc_open(uint32_t locationID, uint16_t vendor, uint16_t product);
void uvc_close(UVCCamera *camera);

/// Which controls the unit declares, as the bitmap from its descriptor.
uint32_t uvc_controls(const UVCCamera *camera, UVCUnit unit);

/// Reads a control of `length` bytes (1, 2 or 4) into `value`, little-endian and unsigned.
/// Returns 0, or a negative IOKit error.
int uvc_get(const UVCCamera *camera, UVCGet request, UVCUnit unit, int selector, int length, uint32_t *value);

/// Sets a control of `length` bytes. Returns 0, or a negative IOKit error.
int uvc_set(const UVCCamera *camera, UVCUnit unit, int selector, int length, uint32_t value);

#endif
