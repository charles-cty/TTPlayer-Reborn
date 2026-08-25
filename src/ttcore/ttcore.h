#pragma once

/* ttcore: Qt-free C ABI around the existing FFmpeg/DSP/SDL2 audio core.
 *
 * Strings returned by getters are UTF-8. The pointer is a per-calling-thread
 * snapshot valid until the next getter call on that thread (or thread exit).
 * Copy immediately; do not retain the pointer across open/stop/destroy.
 * Spectrum is written into a caller-provided buffer.
 * Callbacks are cdecl and may fire on the audio thread.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(_WIN64)
#  ifdef TTCORE_EXPORTS
#    define TTCORE_API __declspec(dllexport)
#  else
#    define TTCORE_API __declspec(dllimport)
#  endif
#  define TTCORE_CALL __cdecl
#else
#  define TTCORE_API __attribute__((visibility("default")))
#  define TTCORE_CALL
#endif

typedef void* ttcore_player;

typedef enum ttcore_state {
    TTCORE_STOPPED = 0,
    TTCORE_PLAYING = 1,
    TTCORE_PAUSED  = 2
} ttcore_state;

typedef void (TTCORE_CALL *ttcore_progress_cb)(void* userdata, int64_t position_ms);
typedef void (TTCORE_CALL *ttcore_finished_cb)(void* userdata);
typedef void (TTCORE_CALL *ttcore_error_cb)(void* userdata, const char* message);

enum {
    TTCORE_META_STRLEN = 512
};

typedef struct ttcore_metadata {
    char title[TTCORE_META_STRLEN];
    char artist[TTCORE_META_STRLEN];
    char album[TTCORE_META_STRLEN];
    int64_t duration_ms;
} ttcore_metadata;

TTCORE_API ttcore_player TTCORE_CALL ttcore_create(void);
TTCORE_API void TTCORE_CALL ttcore_destroy(ttcore_player player);

/* Returns 1 on success, 0 on failure (error callback fired). */
TTCORE_API int TTCORE_CALL ttcore_open(ttcore_player player, const char* path_utf8);
TTCORE_API void TTCORE_CALL ttcore_play(ttcore_player player);
TTCORE_API void TTCORE_CALL ttcore_pause(ttcore_player player);
TTCORE_API void TTCORE_CALL ttcore_stop(ttcore_player player);
TTCORE_API void TTCORE_CALL ttcore_seek(ttcore_player player, int64_t position_ms);

TTCORE_API ttcore_state TTCORE_CALL ttcore_get_state(ttcore_player player);
TTCORE_API int64_t TTCORE_CALL ttcore_get_position_ms(ttcore_player player);
TTCORE_API int64_t TTCORE_CALL ttcore_get_duration_ms(ttcore_player player);
TTCORE_API const char* TTCORE_CALL ttcore_last_error(ttcore_player player);

/* Volume is 0..100. */
TTCORE_API void TTCORE_CALL ttcore_set_volume(ttcore_player player, int volume);
TTCORE_API int TTCORE_CALL ttcore_get_volume(ttcore_player player);
TTCORE_API void TTCORE_CALL ttcore_set_muted(ttcore_player player, int muted);
TTCORE_API int TTCORE_CALL ttcore_is_muted(ttcore_player player);

TTCORE_API void TTCORE_CALL ttcore_set_eq_enabled(ttcore_player player, int enabled);
TTCORE_API int TTCORE_CALL ttcore_get_eq_enabled(ttcore_player player);
TTCORE_API void TTCORE_CALL ttcore_set_eq_gain(ttcore_player player, int band, double gain_db);
TTCORE_API double TTCORE_CALL ttcore_get_eq_gain(ttcore_player player, int band);
TTCORE_API void TTCORE_CALL ttcore_set_preamp(ttcore_player player, double gain_db);
TTCORE_API double TTCORE_CALL ttcore_get_preamp(ttcore_player player);

/* Balance is -100 (left) .. +100 (right). Applied by DspChain. */
TTCORE_API void TTCORE_CALL ttcore_set_balance(ttcore_player player, int balance);
TTCORE_API int TTCORE_CALL ttcore_get_balance(ttcore_player player);

/* UTF-8, C-side lifetime (until next open/stop/destroy). */
TTCORE_API const char* TTCORE_CALL ttcore_get_title(ttcore_player player);
TTCORE_API const char* TTCORE_CALL ttcore_get_artist(ttcore_player player);
TTCORE_API const char* TTCORE_CALL ttcore_get_album(ttcore_player player);

/* Copy current-file cover bytes (embedded attached pic, else sidecar image
 * next to the audio file). Returns the full size in bytes (0 if none).
 * If out is NULL or cap <= 0, only the size is returned. Otherwise
 * min(size, cap) bytes are copied into out. */
TTCORE_API int TTCORE_CALL ttcore_get_cover(ttcore_player player, unsigned char* out, int cap);

/* Fills caller buffer with left-channel PCM (float, typically -1..1). Returns count written. */
TTCORE_API int TTCORE_CALL ttcore_get_spectrum(ttcore_player player, float* out, int count);

TTCORE_API void TTCORE_CALL ttcore_set_progress_callback(ttcore_player player, ttcore_progress_cb cb, void* userdata);
TTCORE_API void TTCORE_CALL ttcore_set_finished_callback(ttcore_player player, ttcore_finished_cb cb, void* userdata);
TTCORE_API void TTCORE_CALL ttcore_set_error_callback(ttcore_player player, ttcore_error_cb cb, void* userdata);

/* FFmpeg avformat metadata. Returns 1 on success. Independent of a player instance. */
TTCORE_API int TTCORE_CALL ttcore_read_metadata(const char* path_utf8, ttcore_metadata* out);
TTCORE_API int TTCORE_CALL ttcore_write_metadata(const char* path_utf8,
                                                 const char* title_utf8,
                                                 const char* artist_utf8,
                                                 const char* album_utf8);

#ifdef __cplusplus
}
#endif
