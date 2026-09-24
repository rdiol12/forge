package app.forge.github

// One account session, memory only; late responses cannot repopulate a cleared cache.
class APIMemoryCache(private val capacity: Int = 16_777_216, private val lifetime: Long = 30_000_000_000L) {
    data class Entry(val bytes: ByteArray, val etag: String?, val expires: Long, val control: String) { val fresh get() = System.nanoTime() < expires }
    private val values = LinkedHashMap<String, Entry>()
    @Volatile var epoch = 0
        private set
    @Synchronized fun value(key: String) = values[key]
    @Synchronized fun clear() { epoch++; values.clear() }
    @Synchronized fun store(key: String, bytes: ByteArray, etag: String?, epoch: Int, control: String = "") {
        if (epoch != this.epoch) return
        if (control.contains("no-store", true)) { values.remove(key); return }
        if (bytes.size > capacity) return
        values.remove(key)
        while (values.size >= 100 || values.values.sumOf { it.bytes.size } + bytes.size > capacity) values.remove(values.keys.first())
        val maxAge = control.split(',').map { it.trim().lowercase() }.firstOrNull { it.startsWith("max-age=") }?.substringAfter('=')?.trim('"')?.toLongOrNull()
        val ttl = if (control.contains("no-cache", true)) 0 else minOf(lifetime, (maxAge?.coerceIn(0, 30) ?: 30) * 1_000_000_000L)
        values[key] = Entry(bytes, etag, System.nanoTime() + ttl, control)
    }
}
