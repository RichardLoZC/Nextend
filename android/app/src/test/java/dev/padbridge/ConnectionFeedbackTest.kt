package dev.padbridge

import org.junit.Assert.*
import org.junit.Test

class ConnectionFeedbackTest {
    @Test fun disconnectReasonSurvivesIdleAndListenerRecovery() {
        val state = ConnectionFeedback()
        val error = UiText("解码停止", "Decoder stopped")
        state.session(true, null); state.session(false, error)
        state.listener(true, false); state.session(false, null); state.listener(true, true)
        assertEquals(error, state.message)
        state.beginAttempt(); assertNull(state.message)
    }
    @Test fun listenerRecoveryOnlyClearsItsOwnFailure() {
        val state = ConnectionFeedback()
        state.listener(true, false); state.listener(false, false)
        state.listener(true, true); assertNotNull(state.message)
        state.listener(false, true); assertNull(state.message)
    }
    @Test fun successfulConnectionClearsPreviousSessionError() {
        val state = ConnectionFeedback()
        state.session(false, UiText("网络失联", "Network lost"))
        state.session(true, null); assertNull(state.message)
    }
}
