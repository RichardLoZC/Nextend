package org.json
class JSONObject {
 constructor()
 constructor(text:String)
 fun put(key:String,value:Any):JSONObject=this
 fun getString(key:String):String=""
 fun get(key:String):Any=false
 fun has(key:String):Boolean=false
 fun getBoolean(key:String):Boolean=false
 fun optBoolean(key:String,default:Boolean):Boolean=default
}
