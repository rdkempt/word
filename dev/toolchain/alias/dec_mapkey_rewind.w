// want: ["z","hello"] 1
import txt
m = {}
m["z"] = 0
s = copy("hello world")
t = copy(s, 0, 5)
m[decode(t)] = 1
t = copy(s, 6, 11)
out(keys(m) . " " . m["hello"])
