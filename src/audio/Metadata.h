#pragma once

#include <cstdint>
#include <string>

struct AVFormatContext;

struct AudioFileMetadata {
    std::string title;
    std::string artist;
    std::string album;
    int64_t duration_ms = 0;
};

std::string audioMetadataField(const AVFormatContext* fmt, const char* key);
int64_t audioDurationMs(const AVFormatContext* fmt);
bool readAudioFileMetadata(const char* pathUtf8, AudioFileMetadata& out);
bool writeAudioFileMetadata(const char* pathUtf8,
                            const char* titleUtf8,
                            const char* artistUtf8,
                            const char* albumUtf8);
