#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include "letta_lite.h"

// Helper function to convert jstring to C string
const char* jstring_to_cstr(JNIEnv *env, jstring jstr) {
    if (jstr == NULL) return NULL;
    return (*env)->GetStringUTFChars(env, jstr, NULL);
}

// Helper function to release C string from jstring
void release_cstr(JNIEnv *env, jstring jstr, const char* cstr) {
    if (jstr != NULL && cstr != NULL) {
        (*env)->ReleaseStringUTFChars(env, jstr, cstr);
    }
}

// Helper function to convert C string to jstring
jstring cstr_to_jstring(JNIEnv *env, const char* cstr) {
    if (cstr == NULL) return NULL;
    return (*env)->NewStringUTF(env, cstr);
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeInitStorage(JNIEnv *env, jclass clazz, jstring path) {
    const char* cpath = jstring_to_cstr(env, path);
    jint result = letta_init_storage(cpath);
    release_cstr(env, path, cpath);
    return result;
}

JNIEXPORT jlong JNICALL
Java_ai_letta_lite_LettaLite_nativeCreateAgent(JNIEnv *env, jobject thiz, jstring config_json) {
    const char* config = jstring_to_cstr(env, config_json);
    AgentHandle* handle = letta_create_agent(config);
    release_cstr(env, config_json, config);
    return (jlong)(intptr_t)handle;
}

JNIEXPORT void JNICALL
Java_ai_letta_lite_LettaLite_nativeFreeAgent(JNIEnv *env, jobject thiz, jlong handle) {
    letta_free_agent((AgentHandle*)(intptr_t)handle);
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeLoadAF(JNIEnv *env, jobject thiz, jlong handle, jstring json) {
    const char* cjson = jstring_to_cstr(env, json);
    jint result = letta_load_af((AgentHandle*)(intptr_t)handle, cjson);
    release_cstr(env, json, cjson);
    return result;
}

JNIEXPORT jstring JNICALL
Java_ai_letta_lite_LettaLite_nativeExportAF(JNIEnv *env, jobject thiz, jlong handle) {
    char* result = letta_export_af((AgentHandle*)(intptr_t)handle);
    if (result == NULL) return NULL;
    
    jstring jresult = cstr_to_jstring(env, result);
    letta_free_str(result);
    return jresult;
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeSetBlock(JNIEnv *env, jobject thiz, jlong handle, 
                                            jstring label, jstring value) {
    const char* clabel = jstring_to_cstr(env, label);
    const char* cvalue = jstring_to_cstr(env, value);
    
    jint result = letta_set_block((AgentHandle*)(intptr_t)handle, clabel, cvalue);
    
    release_cstr(env, label, clabel);
    release_cstr(env, value, cvalue);
    return result;
}

JNIEXPORT jstring JNICALL
Java_ai_letta_lite_LettaLite_nativeGetBlock(JNIEnv *env, jobject thiz, jlong handle, jstring label) {
    const char* clabel = jstring_to_cstr(env, label);
    char* result = letta_get_block((AgentHandle*)(intptr_t)handle, clabel);
    release_cstr(env, label, clabel);
    
    if (result == NULL) return NULL;
    
    jstring jresult = cstr_to_jstring(env, result);
    letta_free_str(result);
    return jresult;
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeAppendArchival(JNIEnv *env, jobject thiz, jlong handle,
                                                  jstring folder, jstring text) {
    const char* cfolder = jstring_to_cstr(env, folder);
    const char* ctext = jstring_to_cstr(env, text);
    
    jint result = letta_append_archival((AgentHandle*)(intptr_t)handle, cfolder, ctext);
    
    release_cstr(env, folder, cfolder);
    release_cstr(env, text, ctext);
    return result;
}

JNIEXPORT jstring JNICALL
Java_ai_letta_lite_LettaLite_nativeSearchArchival(JNIEnv *env, jobject thiz, jlong handle,
                                                  jstring query, jint top_k) {
    const char* cquery = jstring_to_cstr(env, query);
    char* result = letta_search_archival((AgentHandle*)(intptr_t)handle, cquery, top_k);
    release_cstr(env, query, cquery);
    
    if (result == NULL) return NULL;
    
    jstring jresult = cstr_to_jstring(env, result);
    letta_free_str(result);
    return jresult;
}

JNIEXPORT jstring JNICALL
Java_ai_letta_lite_LettaLite_nativeConverse(JNIEnv *env, jobject thiz, jlong handle, jstring message_json) {
    const char* cmessage = jstring_to_cstr(env, message_json);
    char* result = letta_converse((AgentHandle*)(intptr_t)handle, cmessage);
    release_cstr(env, message_json, cmessage);
    
    if (result == NULL) return NULL;
    
    jstring jresult = cstr_to_jstring(env, result);
    letta_free_str(result);
    return jresult;
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeConfigureSync(JNIEnv *env, jclass clazz, jstring config_json) {
    const char* cconfig = jstring_to_cstr(env, config_json);
    jint result = letta_configure_sync(cconfig);
    release_cstr(env, config_json, cconfig);
    return result;
}

JNIEXPORT jint JNICALL
Java_ai_letta_lite_LettaLite_nativeSyncWithCloud(JNIEnv *env, jobject thiz, jlong handle) {
    return letta_sync_with_cloud((AgentHandle*)(intptr_t)handle);
}