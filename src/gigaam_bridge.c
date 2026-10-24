// GigaAM v3 (Сбер) через sherpa-onnx — замена whisper.cpp (25.10.2026).
// Снаружи тот же API, что был у whisper_bridge.c (см. whisper_bridge.h),
// поэтому Swift-часть почти не менялась.
//
// Почему GigaAM: в 3,5 раза меньше large-v3-turbo (225 МБ int8), сам ставит
// точки и запятые (вариант ctc-punct), а на тишине CTC выдаёт пустоту —
// «Субтитры сделал DimaTorzok» и прочих призраков Whisper у него нет.
// Замер на M5 (4 потока CPU): 11,3 с речи -> ~1,0 с, память ~370 МБ.
// CoreML-провайдер onnxruntime проверен — быстрее не стало, поэтому CPU.
//
// accurate / full_ctx / prompt — параметры Whisper, тут не нужны и игнорируются.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include "sherpa-onnx/c-api/c-api.h"
#include "whisper_bridge.h"

static const SherpaOnnxOfflineRecognizer *rec = NULL;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

// Сколько потоков. Задаётся один раз при загрузке (у sherpa-onnx — на распознаватель).
#define GIGA_THREADS 4

int rubai_load(const char *model_dir) {
    pthread_mutex_lock(&mu);
    if (rec) { pthread_mutex_unlock(&mu); return 0; }
    char model[2048], tokens[2048];
    snprintf(model, sizeof model, "%s/model.int8.onnx", model_dir);
    snprintf(tokens, sizeof tokens, "%s/tokens.txt", model_dir);

    SherpaOnnxOfflineRecognizerConfig c;
    memset(&c, 0, sizeof c);
    c.feat_config.sample_rate = 16000;
    c.feat_config.feature_dim = 64;
    c.model_config.nemo_ctc.model = model;
    c.model_config.tokens = tokens;
    c.model_config.num_threads = GIGA_THREADS;
    c.model_config.provider = "cpu";
    c.decoding_method = "greedy_search";
    rec = SherpaOnnxCreateOfflineRecognizer(&c);
    int rc = rec ? 0 : 1;
    pthread_mutex_unlock(&mu);
    return rc;
}

void rubai_set_accuracy(int accurate) { (void)accurate; }

void rubai_unload(void) {
    pthread_mutex_lock(&mu);
    if (rec) { SherpaOnnxDestroyOfflineRecognizer(rec); rec = NULL; }
    pthread_mutex_unlock(&mu);
}

// Один кусок (до ~22 с) -> текст. Пишет в out (дописывает через пробел).
static void decode_piece(const float *s, int n, char **out, size_t *len) {
    const SherpaOnnxOfflineStream *st = SherpaOnnxCreateOfflineStream(rec);
    if (!st) return;
    SherpaOnnxAcceptWaveformOffline(st, 16000, s, n);
    SherpaOnnxDecodeOfflineStream(rec, st);
    const SherpaOnnxOfflineRecognizerResult *r = SherpaOnnxGetOfflineStreamResult(st);
    if (r && r->text && r->text[0]) {
        const char *t = r->text;
        while (*t == ' ') t++;
        size_t add = strlen(t);
        if (add) {
            *out = realloc(*out, *len + add + 2);
            if (*len) (*out)[(*len)++] = ' ';
            memcpy(*out + *len, t, add);
            *len += add;
            (*out)[*len] = 0;
        }
    }
    if (r) SherpaOnnxDestroyOfflineRecognizerResult(r);
    SherpaOnnxDestroyOfflineStream(st);
}

// GigaAM учили на фразах до ~25 с. Длинную запись (режим без потокового
// распознавания) режем на куски по 15–22 с в самом тихом месте (окно 20 мс),
// чтобы не разрезать слово.
#define WIN 320
#define MIN_PIECE (15 * 16000)
#define MAX_PIECE (22 * 16000)

static int quietest_cut(const float *s, int n) {
    int best = MAX_PIECE; double bestE = 1e30;
    for (int at = MIN_PIECE; at + WIN <= MAX_PIECE && at + WIN <= n; at += WIN) {
        double e = 0;
        for (int i = 0; i < WIN; i++) e += (double)s[at + i] * s[at + i];
        if (e < bestE) { bestE = e; best = at + WIN / 2; }
    }
    return best;
}

char *rubai_transcribe(const float *samples, int n_samples, int n_threads,
                       int accurate, int full_ctx, const char *prompt) {
    (void)n_threads; (void)accurate; (void)full_ctx; (void)prompt;
    pthread_mutex_lock(&mu);
    if (!rec) { pthread_mutex_unlock(&mu); return NULL; }
    char *out = calloc(1, 1);
    size_t len = 0;
    int pos = 0;
    while (n_samples - pos > MAX_PIECE) {
        int cut = quietest_cut(samples + pos, n_samples - pos);
        decode_piece(samples + pos, cut, &out, &len);
        pos += cut;
    }
    if (n_samples - pos > 0) decode_piece(samples + pos, n_samples - pos, &out, &len);
    pthread_mutex_unlock(&mu);
    return out;
}

void rubai_free_str(char *s) { free(s); }
