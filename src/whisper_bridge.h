#ifndef RUBAI_WHISPER_BRIDGE_H
#define RUBAI_WHISPER_BRIDGE_H

// Modelni yuklaydi (bir marta). 0 = muvaffaqiyat.
int rubai_load(const char *model_path);

// Modelni (va kerak bo'lsa ru-modelni) oldindan yuklaydi. 0 = muvaffaqiyat.
int rubai_preload(const char *model_path, const char *lang);

// Keyingi rubai_transcribe uchun tilni belgilaydi: "uz" yoki "ru".
void rubai_set_language(const char *lang);

// 0 = tez (greedy), 1 = aniqroq (beam search 3, ~2 barobar sekin).
void rubai_set_accuracy(int accurate);

// Modelni RAM'dan bo'shatadi.
void rubai_unload(void);

// 16kHz mono float32 namunalardan matn qaytaradi.
// Qaytgan satrni rubai_free_str bilan bo'shating. NULL = xato.
char *rubai_transcribe(const float *samples, int n_samples, int n_threads);

void rubai_free_str(char *s);

#endif
