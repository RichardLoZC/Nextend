package dev.padbridge

import org.json.JSONObject

object PadPreferences {
    fun validate(json: JSONObject): JSONObject {
        require(json.get("showFPS") is Boolean)
        require(json.getString("language") in listOf("zh", "en"))
        require(Regex("#[0-9a-fA-F]{6}").matches(json.getString("color")))
        for ((name, range) in listOf("size" to 12..64, "font" to 0..2)) {
            val v = json.get(name); require(v is Number && v.toDouble() == v.toInt().toDouble() && v.toInt() in range)
        }
        for (name in listOf("x", "y")) { val v = json.get(name); require(v is Number && v.toDouble().isFinite() && v.toDouble() in 0.0..1.0) }
        return json
    }
}
