package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	msg := os.Getenv("DEMO_BACKEND_MESSAGE")
	if msg == "" {
		msg = "Hello from demo-backend"
	}

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	http.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"message": msg})
	})

	log.Println("demo-backend listening on :8000")
	log.Fatal(http.ListenAndServe(":8000", nil))
}
