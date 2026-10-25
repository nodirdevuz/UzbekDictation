// rubai-asr — отдельный процесс распознавания (25.10.2026).
//
// Зачем: sherpa-onnx/onnxruntime после SherpaOnnxDestroyOfflineRecognizer держат
// ~450 МБ (не утечка — живой глобальный кэш, `leaks` его не видит). В самом
// приложении эту память не вернуть, а владелец требует «не нагружал, когда не
// использую». Поэтому модель живёт в этом процессе: приложение запускает его на
// ⌘⌘ и закрывает через 2 мин простоя — память освобождается вся.
//
// Протокол по stdin/stdout (всё little-endian, как на arm64):
//   старт:   helper пишет int32 0 (модель загружена) или -1 (ошибка) и выходит при -1
//   запрос:  int32 n (>0), затем n float32 (16 кГц моно)
//   ответ:   int32 len, затем len байт UTF-8 текста
//   EOF / n<=0 — выход.
#include <unistd.h>
#include "gigaam_bridge.c"

static int read_all(void *buf, size_t n) {
    char *p = buf;
    while (n) {
        ssize_t r = read(0, p, n);
        if (r <= 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

static int write_all(const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = write(1, p, n);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

int main(int argc, char **argv) {
    int32_t st = (argc > 1 && rubai_load(argv[1]) == 0) ? 0 : -1;
    if (write_all(&st, 4) || st) return 1;
    for (;;) {
        int32_t n;
        if (read_all(&n, 4) || n <= 0) break;
        float *s = malloc((size_t)n * sizeof(float));
        if (!s || read_all(s, (size_t)n * sizeof(float))) break;
        char *t = rubai_transcribe(s, n, 0, 0, 0, NULL);
        free(s);
        int32_t len = t ? (int32_t)strlen(t) : 0;
        if (write_all(&len, 4) || (len && write_all(t, (size_t)len))) break;
        free(t);
    }
    return 0;
}
