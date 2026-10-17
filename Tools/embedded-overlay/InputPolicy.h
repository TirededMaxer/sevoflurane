/* CrossOver 26.3 MACDRV event prefix, from macdrv_cocoa.h.
 * Copyright 2011, 2012, 2013 Ken Thomases for CodeWeavers Inc.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * The complete event remains owned by Wine; this adapter only reads its
 * discriminator and the mouse-button pressed flag. Other Wine ABIs must
 * supply their own adapter rather than reusing these offsets.
 */
#ifndef SEVO_OVERLAY_INPUT_POLICY_H
#define SEVO_OVERLAY_INPUT_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
    int refs, deliver, type;
    void *window;
    union { struct { int button; bool pressed; } mouseButton; } payload;
} SevoCX263EventPrefix;
_Static_assert(offsetof(SevoCX263EventPrefix, type) == 8, "CrossOver 26.3 event type ABI");
_Static_assert(offsetof(SevoCX263EventPrefix, payload) == 24, "CrossOver 26.3 event payload ABI");
static inline bool SevoOverlayBlocksWineEvent(const SevoCX263EventPrefix *event, bool active) {
    if (!event || !active) return false;
    switch (event->type) {
        case 6:  /* HOTKEY_PRESS */
        case 7:  /* IM_SET_TEXT */
        case 8:  /* KEY_PRESS */
        case 13: /* MOUSE_MOVED_RELATIVE */
        case 14: /* MOUSE_MOVED_ABSOLUTE */
        case 15: /* MOUSE_MOVED_RAW: bypasses NSApplication.sendEvent */
        case 16: /* MOUSE_SCROLL: can arrive directly from HID */
            return true;
        case 12: /* Release a button the game held before opening the overlay. */
            return event->payload.mouseButton.pressed;
        default: /* KEY_RELEASE, focus, resize and lifecycle events still flow. */
            return false;
    }
}
#endif
