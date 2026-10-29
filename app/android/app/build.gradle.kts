import java.util.Properties

plugins {
    id("com.android.application")
    // Flutter 插件必须在 Android 插件之后应用。
    id("dev.flutter.flutter-gradle-plugin")
}

val signing = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

val requireReleaseSigning = tasks.register("requireReleaseSigning") {
    doLast {
        check(listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all {
            !signing.getProperty(it).isNullOrBlank()
        }) { "正式构建缺少完整的签名配置，请配置 android/key.properties" }
        check(file(signing.getProperty("storeFile")).isFile) {
            "正式构建的签名密钥文件不存在"
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(requireReleaseSigning)
}

android {
    namespace = "com.ecycloud.client"
    compileSdk = 37
    buildToolsVersion = "37.0.0"
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        aidl = true
    }

    defaultConfig {
        applicationId = "com.ecycloud.client"
        // 与 scripts/build-libmihomo.sh 的 -androidapi 必须一致
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signing.containsKey("storeFile")) {
            create("release") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(files("libs/libmihomo.aar"))
    implementation("androidx.core:core-ktx:1.19.1")
}

flutter {
    source = "../.."
}
