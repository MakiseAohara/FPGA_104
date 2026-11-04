#ifndef MMT_FRAME_LAYOUT_H
#define MMT_FRAME_LAYOUT_H
/* Actual netfix04_rxq2 hierarchy, verified in 1-map.log:
 * frame_buffer.MAX_VID_WIDTH=960 is NOT forwarded to ddr_buffer.
 * ddr_buffer/bank_switch therefore use width=1920, height=1080,
 * VID_DATA_WIDTH=32. This is reserved bank capacity, not image line size.
 * MIPI contributes four uint8 Bayer samples per 32-bit word; image rows
 * remain 1920 packed uint8 pixels (480 input words per actual sensor row).
 * Keep bank 1, the same physical bank previously reached accidentally at
 * bank1+512. A future RTL handshake is needed to pin a completed bank. */
#define MMT_FB_DDR_BASE              0x01000000u
#define MMT_FB_BANK_COUNT            3u
#define MMT_FB_RESERVED_WIDTH        1920u
#define MMT_FB_RESERVED_HEIGHT       1080u
#define MMT_FB_RESERVED_WORD_BYTES   4u
#define MMT_FB_BANK_GUARD_BYTES      0x200u
#define MMT_FB_BANK_STRIDE_BYTES     (MMT_FB_RESERVED_WIDTH * MMT_FB_RESERVED_HEIGHT * MMT_FB_RESERVED_WORD_BYTES + MMT_FB_BANK_GUARD_BYTES)
#define MMT_FB_CAPTURE_BANK          1u
#define MMT_FB_CAPTURE_BASE          (MMT_FB_DDR_BASE + MMT_FB_CAPTURE_BANK * MMT_FB_BANK_STRIDE_BYTES)
#define MMT_FB_IMAGE_WIDTH           1920u
#define MMT_FB_IMAGE_HEIGHT          1080u
#define MMT_FB_PIXEL_BYTES           1u
#define MMT_FB_ROW_BYTES             (MMT_FB_IMAGE_WIDTH * MMT_FB_PIXEL_BYTES)
#endif
