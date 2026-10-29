package com.ecycloud.client

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import org.json.JSONObject
import java.io.File
import java.util.Locale

object NativeLanguage {
    fun resources(context: Context): Resources {
        val language = runCatching {
            JSONObject(File(context.filesDir, "settings.json").readText()).optString("locale")
        }.getOrDefault("")
        if (language !in setOf("zh_CN", "zh_TW", "zh-CN", "zh-TW", "en-US", "en")) {
            return context.resources
        }
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(language.replace('_', '-')))
        return context.createConfigurationContext(configuration).resources
    }
}
