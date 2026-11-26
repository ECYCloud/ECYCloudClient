package com.ecycloud.client

object NativeRecovery {
    // 界面进程在且未冻结时 Dart 1～2.4 秒内自己重启隧道，原生侧先让它
    const val GRACE_MS = 5_000L
    const val STABLE_MS = 60_000L

    // 次数与间隔同 Dart 侧内核异常退出的重启：第一次在宽限期后，此后 1/2/4/8/16 秒，用完立即收手
    const val MAX_ATTEMPTS = 6
    private val backoffMs = longArrayOf(1_000, 2_000, 4_000, 8_000, 16_000)

    // attempts 为空即没有接管标记（从未接管或已正常停止）
    fun shouldRecover(attempts: Int?, stopReason: String?, hasConfig: Boolean): Boolean =
        attempts != null && attempts < MAX_ATTEMPTS && stopReason == null && hasConfig

    fun retryDelayMs(attempts: Int): Long = backoffMs.getOrElse(attempts - 1) { 0 }
}
