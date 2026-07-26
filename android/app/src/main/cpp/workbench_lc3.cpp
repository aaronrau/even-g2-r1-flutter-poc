#include <jni.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "lc3.h"

namespace {

constexpr int kFrameDurationUs = 10000;
constexpr int kSampleRateHz = 16000;

jlong InitDecoder(JNIEnv *, jobject) {
  const unsigned size = lc3_decoder_size(kFrameDurationUs, kSampleRateHz);
  void *memory = std::malloc(size);
  if (memory == nullptr) {
    return 0;
  }
  if (lc3_setup_decoder(
          kFrameDurationUs,
          kSampleRateHz,
          0,
          memory) == nullptr) {
    std::free(memory);
    return 0;
  }
  return reinterpret_cast<jlong>(memory);
}

void FreeDecoder(JNIEnv *, jobject, jlong pointer) {
  std::free(reinterpret_cast<void *>(pointer));
}

jbyteArray Decode(
    JNIEnv *environment,
    jobject,
    jlong pointer,
    jbyteArray input,
    jint frame_size) {
  if (pointer == 0 || input == nullptr || frame_size <= 0) {
    return environment->NewByteArray(0);
  }

  const jsize input_size = environment->GetArrayLength(input);
  if (input_size <= 0 || input_size % frame_size != 0) {
    return environment->NewByteArray(0);
  }

  const int samples_per_frame =
      lc3_frame_samples(kFrameDurationUs, kSampleRateHz);
  const int frame_count = input_size / frame_size;
  const int output_size =
      frame_count * samples_per_frame * static_cast<int>(sizeof(int16_t));

  jboolean copied = JNI_FALSE;
  jbyte *input_bytes =
      environment->GetByteArrayElements(input, &copied);
  if (input_bytes == nullptr) {
    return environment->NewByteArray(0);
  }

  auto *output = static_cast<int16_t *>(
      std::calloc(frame_count * samples_per_frame, sizeof(int16_t)));
  if (output == nullptr) {
    environment->ReleaseByteArrayElements(input, input_bytes, JNI_ABORT);
    return environment->NewByteArray(0);
  }

  auto *decoder = reinterpret_cast<lc3_decoder_t>(pointer);
  bool failed = false;
  for (int frame = 0; frame < frame_count; ++frame) {
    const void *encoded = input_bytes + frame * frame_size;
    int16_t *decoded = output + frame * samples_per_frame;
    if (lc3_decode(
            decoder,
            encoded,
            frame_size,
            LC3_PCM_FORMAT_S16,
            decoded,
            1) < 0) {
      failed = true;
      break;
    }
  }

  environment->ReleaseByteArrayElements(input, input_bytes, JNI_ABORT);
  jbyteArray result =
      environment->NewByteArray(failed ? 0 : output_size);
  if (!failed && result != nullptr) {
    environment->SetByteArrayRegion(
        result,
        0,
        output_size,
        reinterpret_cast<const jbyte *>(output));
  }
  std::free(output);
  return result;
}

const JNINativeMethod kMethods[] = {
    {
        const_cast<char *>("nativeInitDecoder"),
        const_cast<char *>("()J"),
        reinterpret_cast<void *>(InitDecoder),
    },
    {
        const_cast<char *>("nativeDecode"),
        const_cast<char *>("(J[BI)[B"),
        reinterpret_cast<void *>(Decode),
    },
    {
        const_cast<char *>("nativeFreeDecoder"),
        const_cast<char *>("(J)V"),
        reinterpret_cast<void *>(FreeDecoder),
    },
};

}  // namespace

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *environment = nullptr;
  if (vm->GetEnv(
          reinterpret_cast<void **>(&environment),
          JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass decoder_class = environment->FindClass(
      "dev/opensourceglasses/even_g2_r1_poc/WorkBenchLc3");
  if (decoder_class == nullptr) {
    return JNI_ERR;
  }
  if (environment->RegisterNatives(
          decoder_class,
          kMethods,
          sizeof(kMethods) / sizeof(kMethods[0])) != JNI_OK) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}
