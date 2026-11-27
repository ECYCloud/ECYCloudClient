import java.util.Base64
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

// 与 Dart AppConfig.siteBaseUrl 同源：原生侧补算旧版凭据缺失的账号键时要用到站点地址
val dartSiteUrl: String = (findProperty("dart-defines") as String?).orEmpty()
    .split(',')
    .filter { it.isNotBlank() }
    .map { String(Base64.getDecoder().decode(it)) }
    .firstOrNull { it.startsWith("ECYCLOUD_SITE_URL=") }
    ?.substringAfter('=')
    .orEmpty()

val requireReleaseSigning = tasks.register("requireReleaseSigning") {
    onlyIf { !signing.isEmpty() }
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
        buildConfigField("String", "SITE_URL", "\"${dartSiteUrl.replace("\\", "\\\\").replace("\"", "\\\"")}\"")
    }

    signingConfigs {
        if (signing.containsKey("storeFile")) {
            create("release") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
                // minSdk 24 时默认只签 v2，部分国产系统安装器找不到 v1 证书会拒装
                enableV1Signing = true
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
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
