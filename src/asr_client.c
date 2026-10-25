// Сторона приложения: тот же API, что whisper_bridge.h, но модель живёт в
// отдельном процессе rubai-asr (см. asr_helper.c — там описано, зачем).
// rubai_load запускает его, rubai_unload закрывает — и вся память модели уходит.
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <spawn.h>
#include <pthread.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include "whisper_bridge.h"

extern char **environ;

static pid_t child = 0;
static int to_child = -1, from_child = -1;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

static int read_all(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

// Закрыть трубы и дождаться выхода. Закрытый stdin = EOF = helper выходит сам.
static void stop_child(void) {
    if (to_child >= 0) close(to_child);
    if (from_child >= 0) close(from_child);
    to_child = from_child = -1;
    if (child > 0) {
        int st;
        for (int i = 0; i < 40 && waitpid(child, &st, WNOHANG) == 0; i++) usleep(50000);
        if (waitpid(child, &st, WNOHANG) == 0) { kill(child, SIGKILL); waitpid(child, &st, 0); }
    }
    child = 0;
}

int rubai_load(const char *model_dir) {
    pthread_mutex_lock(&mu);
    if (child > 0) { pthread_mutex_unlock(&mu); return 0; }
    signal(SIGPIPE, SIG_IGN);   // helper упал — write вернёт ошибку, а не убьёт приложение

    // rubai-asr лежит рядом с основным бинарником в Contents/MacOS
    char exe[4096], helper[4200];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) != 0) { pthread_mutex_unlock(&mu); return 1; }
    char *slash = strrchr(exe, '/');
    if (slash) *slash = 0;
    snprintf(helper, sizeof helper, "%s/rubai-asr", exe);

    int in[2], out[2];
    if (pipe(in) || pipe(out)) { pthread_mutex_unlock(&mu); return 1; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, in[0], 0);
    posix_spawn_file_actions_adddup2(&fa, out[1], 1);
    posix_spawn_file_actions_addclose(&fa, in[1]);
    posix_spawn_file_actions_addclose(&fa, out[0]);
    char *args[] = { helper, (char *)model_dir, NULL };
    int rc = posix_spawn(&child, helper, &fa, NULL, args, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(in[0]); close(out[1]);
    to_child = in[1]; from_child = out[0];

    int32_t st = -1;
    if (rc != 0) child = 0;
    if (rc != 0 || read_all(from_child, &st, 4) || st != 0) {
        stop_child();
        pthread_mutex_unlock(&mu);
        return 1;
    }
    pthread_mutex_unlock(&mu);
    return 0;
}

void rubai_set_accuracy(int accurate) { (void)accurate; }

void rubai_unload(void) {
    pthread_mutex_lock(&mu);
    stop_child();
    pthread_mutex_unlock(&mu);
}

char *rubai_transcribe(const float *samples, int n_samples, int n_threads,
                       int accurate, int full_ctx, const char *prompt) {
    (void)n_threads; (void)accurate; (void)full_ctx; (void)prompt;
    pthread_mutex_lock(&mu);
    if (child <= 0 || n_samples <= 0) { pthread_mutex_unlock(&mu); return NULL; }
    int32_t n = n_samples, len = 0;
    char *out = NULL;
    if (write_all(to_child, &n, 4) == 0
        && write_all(to_child, samples, (size_t)n * sizeof(float)) == 0
        && read_all(from_child, &len, 4) == 0 && len >= 0) {
        out = malloc((size_t)len + 1);
        if (out && (len == 0 || read_all(from_child, out, (size_t)len) == 0)) out[len] = 0;
        else { free(out); out = NULL; }
    }
    // Связь оборвалась (helper упал) — закрываем; Swift-часть при следующей
    // диктовке снова вызовет rubai_load, и процесс поднимется заново.
    if (!out) stop_child();
    pthread_mutex_unlock(&mu);
    return out;
}

void rubai_free_str(char *s) { free(s); }
