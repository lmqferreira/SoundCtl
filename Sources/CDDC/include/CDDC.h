#ifndef CDDC_H
#define CDDC_H

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// Private IOAVService API (Apple Silicon DDC/CI over the display link).
// These symbols are exported by the system but not declared in any public
// header. They are used the same way by MonitorControl / BetterDisplay.
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator,
                                                   io_service_t service);

extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t offset,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);

#endif /* CDDC_H */
