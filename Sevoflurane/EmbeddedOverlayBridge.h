#include <stdint.h>
void *SevoOverlayCreate(const char *path);
uint64_t SevoOverlayRead(void *map, uint32_t word);
void SevoOverlayDeactivate(void *map);
void SevoOverlayPublish(void *map, const void *pixels, uint32_t width, uint32_t height);
int SevoOverlayPop(void *map, void *packet);
