// want: hello
keep(box, v)
    return 0
keep:before
    box[0] = v
    return true
arr = array(1)
s = copy("hello world")
t = copy(s, 0, 5)
keep(arr, t)
t = copy(s, 6, 11)
out(arr[0])
