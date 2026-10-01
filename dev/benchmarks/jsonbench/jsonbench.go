package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	text, err := os.ReadFile("data.json")
	if err != nil {
		fmt.Fprintln(os.Stderr, "run gen.w first")
		os.Exit(1)
	}
	var docs []map[string]interface{}
	if err := json.Unmarshal(text, &docs); err != nil {
		fmt.Fprintln(os.Stderr, "parse failed")
		os.Exit(1)
	}
	sum, active := 0, 0
	for _, rec := range docs {
		sum += int(rec["score"].(float64))
		active += int(rec["active"].(float64))
	}
	out, _ := json.Marshal(docs)
	fmt.Println(len(docs), sum, active, len(out))
}
