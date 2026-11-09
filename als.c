#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kALS 12
int main(int argc, char **argv) {
  int once = argc > 1;
  int page = 0xff00, usage = 4;
  CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
  const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
  CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(NULL);
  IOHIDEventSystemClientSetMatching(c, m);
  CFArrayRef s = IOHIDEventSystemClientCopyServices(c);
  if (!s || !CFArrayGetCount(s)) { fprintf(stderr, "ALS service not found\n"); return 1; }
  IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(s, 0);
  for (;;) {
    IOHIDEventRef e = IOHIDServiceClientCopyEvent(svc, kALS, 0, 0);
    if (e) { printf("\rALS level: %10.2f   ", IOHIDEventGetFloatValue(e, kALS << 16)); fflush(stdout); CFRelease(e); }
    else { printf("\r(no event)            "); fflush(stdout); }
    if (once) { printf("\n"); break; }
    usleep(200000);
  }
}
