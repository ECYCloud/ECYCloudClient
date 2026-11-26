package com.ecycloud.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeRecoveryTest {
    @Test
    fun recoversOnlyAnUnfinishedTakeoverWithConfig() {
        assertTrue(NativeRecovery.shouldRecover(0, null, true))
        assertTrue(NativeRecovery.shouldRecover(5, null, true))
        assertFalse(NativeRecovery.shouldRecover(null, null, true))
        assertFalse(NativeRecovery.shouldRecover(0, BoxState.STOPPED_BY_USER, true))
        assertFalse(NativeRecovery.shouldRecover(0, BoxState.REVOKED, true))
        assertFalse(NativeRecovery.shouldRecover(0, null, false))
    }

    @Test
    fun givesUpAfterSixConsecutiveAttempts() {
        assertFalse(NativeRecovery.shouldRecover(6, null, true))
        assertFalse(NativeRecovery.shouldRecover(7, null, true))
    }

    @Test
    fun retriesFollowTheDartBackoffThenStopWaiting() {
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 0L),
            (1..6).map(NativeRecovery::retryDelayMs),
        )
    }
}
