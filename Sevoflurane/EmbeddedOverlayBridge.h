#include <stdint.h>
void * _Nullable SevoOverlayCreate(const char * _Nonnull path);
uint64_t SevoOverlayRead(void * _Nonnull map, uint32_t word);
void SevoOverlayDeactivate(void * _Nonnull map);
void SevoOverlayPublish(void * _Nonnull map, const void * _Nonnull pixels, uint32_t width, uint32_t height);
int SevoOverlayPop(void * _Nonnull map, void * _Nonnull packet);
