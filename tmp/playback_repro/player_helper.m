#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

void *repro_player_start(const char *path) {
    @autoreleasepool {
        NSString *string = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:string];
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
        if (!player) return NULL;
        [player prepareToPlay];
        if (![player play]) {
            [player release];
            return NULL;
        }
        return player;
    }
}

int repro_player_is_playing(void *opaque) {
    return opaque && [(AVAudioPlayer *)opaque isPlaying] ? 1 : 0;
}

double repro_player_current_time(void *opaque) {
    return opaque ? [(AVAudioPlayer *)opaque currentTime] : -1.0;
}

double repro_player_duration(void *opaque) {
    return opaque ? [(AVAudioPlayer *)opaque duration] : -1.0;
}

void repro_player_stop(void *opaque) {
    if (!opaque) return;
    AVAudioPlayer *player = (AVAudioPlayer *)opaque;
    [player stop];
    [player release];
}
