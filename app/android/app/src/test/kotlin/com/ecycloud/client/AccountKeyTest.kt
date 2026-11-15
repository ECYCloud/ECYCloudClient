package com.ecycloud.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// 期望值由 Dart AuthController 登录后写入的 session_key 实际算出
class AccountKeyTest {
    @Test
    fun matchesDartForSavedSite() {
        assertEquals(
            "7a67cd48066246e527d304796ec0be7e625f6c13aedb70a9b82a423cc47f7aa3",
            AccountKey.of("https://panel.example.test", "", "User@Example.COM"),
        )
        assertEquals(
            "99ed51e4e0ad254cfaa2e8ea72935e5a91fe8c7809b62ef40d81d8cf8057430c",
            AccountKey.of("https://Panel.Example.test:8443/", "", "  a@b.test "),
        )
        assertEquals(
            "ae1536a72c0f65cb8a69e9891e9fee20f0c38389ff62d31b1fdb5ca57d76b9d2",
            AccountKey.of("https://panel.example.test:443", "", "quote\"back\\slash/x@y.test"),
        )
        assertEquals(
            "ab4f04a7da37d57909eb9d000e719b1abff31caed85d9cfd22ab2b7770cc24e1",
            AccountKey.of("https://panel.example.test", "", "tab\there\u0001@x.test"),
        )
    }

    @Test
    fun matchesDartForBundledSiteAndUnicode() {
        assertEquals(
            "ceb977aab2c05b0e9c07d8415e76f4feb480af93aaf1356110df3b2c888eb8b5",
            AccountKey.of("", "https://bundled.example.test/path", "用户@例子.测试"),
        )
        assertEquals(
            "70e262367b60eed9cd568098ad4923b974c1d587d57ee0fc717d23b4ef5582d2",
            AccountKey.of("http://insecure.test", "https://fallback.test", "Ünïcödé@Exämple.TEST"),
        )
    }

    @Test
    fun rejectsMissingIdentity() {
        assertNull(AccountKey.of("http://insecure.test", "", "a@b.test"))
        assertNull(AccountKey.of("https://panel.example.test", "", "   "))
    }
}
