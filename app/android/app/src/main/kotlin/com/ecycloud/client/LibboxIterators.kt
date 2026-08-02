package com.ecycloud.client

import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

class StringArray(private val values: List<String>) : StringIterator {
    private var index = 0

    override fun len(): Int = values.size

    override fun hasNext(): Boolean = index < values.size

    override fun next(): String = values[index++]
}

class InterfaceArray(private val values: List<LibboxNetworkInterface>) : NetworkInterfaceIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < values.size

    override fun next(): LibboxNetworkInterface = values[index++]
}
