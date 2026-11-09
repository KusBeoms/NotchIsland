#include "als_bridge.h"
#include <CoreFoundation/CoreFoundation.h>
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kALS 12

static IOHIDEventSystemClientRef client;
static IOHIDServiceClientRef svc;
static int skip_calls;      // back-off after a failed lookup
static int event_misses;    // consecutive reads that produced no event

static void drop(void) {
  if (svc) { CFRelease(svc); svc = NULL; }
  if (client) { CFRelease(client); client = NULL; }
}

double als_read(void) {
  if (!svc) {
    if (skip_calls > 0) { skip_calls--; return -1; }
    int page = 0xff00, usage = 4;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u);
    client = IOHIDEventSystemClientCreate(NULL);
    if (client) IOHIDEventSystemClientSetMatching(client, m);
    CFRelease(m);
    CFArrayRef s = client ? IOHIDEventSystemClientCopyServices(client) : NULL;
    if (s && CFArrayGetCount(s) > 0)
      svc = (IOHIDServiceClientRef)CFRetain(CFArrayGetValueAtIndex(s, 0));   // keep it alive past CFRelease(s)
    if (s) CFRelease(s);
    if (!svc) { drop(); skip_calls = 20; return -1; }   // retry the lookup in ~20 calls
    event_misses = 0;
  }
  IOHIDEventRef e = IOHIDServiceClientCopyEvent(svc, kALS, 0, 0);
  if (!e) {
    if (++event_misses >= 10) { drop(); skip_calls = 0; }   // service went away: look it up again next call
    return -1;
  }
  event_misses = 0;
  double val = IOHIDEventGetFloatValue(e, kALS << 16);
  CFRelease(e);
  return val;
}
