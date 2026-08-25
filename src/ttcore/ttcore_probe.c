/* Standalone consumer of the shipped ttcore C ABI (not the FPCUnit binary). */
#include "ttcore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void on_error(void* userdata, const char* message) {
    (void)userdata;
    fprintf(stderr, "error=%s\n", message ? message : "");
    fflush(stderr);
}

int main(int argc, char** argv) {
    ttcore_player player;
    int64_t duration;
    ttcore_metadata meta;
    const char* path;
    const char* title;

    if (argc < 2) {
        fprintf(stderr, "usage: ttcore_probe <audio-file>\n");
        return 2;
    }
    path = argv[1];

    player = ttcore_create();
    if (!player) {
        fprintf(stderr, "create failed\n");
        return 1;
    }
    ttcore_set_error_callback(player, on_error, NULL);

    if (!ttcore_open(player, path)) {
        fprintf(stderr, "open failed path=%s last_error=%s\n",
                path, ttcore_last_error(player));
        ttcore_destroy(player);
        return 1;
    }

    duration = ttcore_get_duration_ms(player);
    title = ttcore_get_title(player);
    printf("duration_ms=%lld\n", (long long)duration);
    printf("title=%s\n", title ? title : "");
    printf("balance=%d\n", ttcore_get_balance(player));
    ttcore_set_balance(player, 50);
    printf("balance_set=%d\n", ttcore_get_balance(player));
    printf("cover_bytes=%d\n", ttcore_get_cover(player, NULL, 0));
    fflush(stdout);

    memset(&meta, 0, sizeof(meta));
    if (ttcore_read_metadata(path, &meta)) {
        printf("meta_title=%s\n", meta.title);
        printf("meta_artist=%s\n", meta.artist);
        printf("meta_album=%s\n", meta.album);
        printf("meta_duration_ms=%lld\n", (long long)meta.duration_ms);
        fflush(stdout);
    }

    ttcore_destroy(player);
    return 0;
}
