#include "whisper.h"
#include "whisper_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static struct whisper_context *g_ctx = NULL;    // rubaiSTT (uz, ixtisoslashgan)
static struct whisper_context *g_ctx_ru = NULL; // oddiy ko'p tilli Whisper (ru, kirillcha uchun)
static char g_model_dir[900] = {0};

// Joriy til — Swift tomonidan rubai_set_language() orqali beriladi.
// Oldin ~/.rubaistt_lang fayli o'qilardi (Hammerspoon uchun); endi kerak emas.
static char g_lang[8] = "ru";

void rubai_set_language(const char *lang) {
    if (!lang) return;
    if (strcmp(lang, "ru") == 0) strcpy(g_lang, "ru");
    else                         strcpy(g_lang, "uz");
}

int rubai_load(const char *model_path) {
    if (g_ctx) return 0;

    // ru-model shu papkadan izlanadi ("ggml-multilingual.bin"), rubaistt bilan bitta joyda.
    strncpy(g_model_dir, model_path, sizeof(g_model_dir) - 1);
    g_model_dir[sizeof(g_model_dir) - 1] = '\0';
    char *slash = strrchr(g_model_dir, '/');
    if (slash) *slash = '\0'; else g_model_dir[0] = '\0';

    struct whisper_context_params cp = whisper_context_default_params();
    // Metal bu Mac'da (AMD Radeon Pro, Metal 2) CPU'dan ~24 barobar sekin —
    // o'lchandi, shuning uchun GPU o'chirilgan.
    cp.use_gpu = false;
    cp.flash_attn = false;
    g_ctx = whisper_init_from_file_with_params(model_path, cp);
    return g_ctx ? 0 : 1;
}

// ru-context (ko'p tilli small model).
static struct whisper_context *rubai_ru_ctx(void) {
    if (g_ctx_ru) return g_ctx_ru;
    if (g_model_dir[0] == '\0') return NULL;

    char path[1024];
    snprintf(path, sizeof(path), "%s/ggml-multilingual.bin", g_model_dir);

    struct whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;
    cp.flash_attn = false;
    g_ctx_ru = whisper_init_from_file_with_params(path, cp);
    return g_ctx_ru;
}

// Modelni oldindan (fon oqimida) yuklab qo'yish — birinchi diktovkadagi
// ~1.3 s "model yuklanmoqda" kutishini yo'q qiladi.
int rubai_preload(const char *model_path, const char *lang) {
    if (rubai_load(model_path) != 0) return 1;
    if (lang && strcmp(lang, "ru") == 0) return rubai_ru_ctx() ? 0 : 1;
    return 0;
}

void rubai_unload(void) {
    if (g_ctx) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
    if (g_ctx_ru) {
        whisper_free(g_ctx_ru);
        g_ctx_ru = NULL;
    }
}

char *rubai_transcribe(const float *samples, int n_samples, int n_threads) {
    const char *lang = g_lang;

    struct whisper_context *ctx = g_ctx;
    if (strcmp(lang, "ru") == 0) {
        ctx = rubai_ru_ctx(); // kirillcha uchun oddiy ko'p tilli model
    }
    if (!ctx) return NULL;

    // GREEDY — beam search (3) o'rniga. O'lchov (11 s nutq, medium model):
    // beam3 = 10.5 s, greedy = 4.6 s. Aniqlik deyarli o'zgarmaydi.
    struct whisper_full_params p =
        whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.greedy.best_of    = 1;
    p.language          = lang;
    p.translate         = false;
    p.n_threads         = n_threads > 0 ? n_threads : 4;
    p.no_timestamps     = true;
    p.print_progress    = false;
    p.print_realtime    = false;
    p.print_special     = false;
    p.print_timestamps  = false;
    p.suppress_blank    = true;

    // Harorat bo'yicha qayta urinish (fallback) o'chirilgan: "yomon" segmentda
    // whisper dekoderni 5 martagacha qayta yurgizadi — kutish bir necha barobar
    // oshadi. Diktovka uchun bitta o'tish yetarli.
    p.temperature       = 0.0f;
    p.temperature_inc   = 0.0f;
    // Oldingi segment matnini prompt sifatida bermaymiz — tezroq va barqarorroq.
    p.no_context        = true;

    // Standart holatda koder har doim to'liq 30 s oynani (1500 pozitsiya)
    // qayta ishlaydi, hatto audio 4 soniya bo'lsa ham — asosiy sekinlik sababi.
    // Haqiqiy uzunlikka moslaymiz (+1.5 s zaxira; ilgari +3 s edi).
    {
        double dur_sec = (double)n_samples / 16000.0;
        int actx = (int)((dur_sec + 0.5) * 50.0);
        if (actx < 256) actx = 256;
        if (actx > 1500) actx = 1500;
        p.audio_ctx = actx;
    }

    if (whisper_full(ctx, p, samples, n_samples) != 0) return NULL;

    int ns = whisper_full_n_segments(ctx);
    size_t len = 0;
    char *out = malloc(1);
    if (!out) return NULL;
    out[0] = '\0';
    for (int i = 0; i < ns; i++) {
        const char *t = whisper_full_get_segment_text(ctx, i);
        if (!t) continue;
        size_t tl = strlen(t);
        char *tmp = realloc(out, len + tl + 1);
        if (!tmp) { free(out); return NULL; }
        out = tmp;
        memcpy(out + len, t, tl);
        len += tl;
        out[len] = '\0';
    }
    return out;
}

void rubai_free_str(char *s) { free(s); }
