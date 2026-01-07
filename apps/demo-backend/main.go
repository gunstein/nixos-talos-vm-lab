package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var db *pgxpool.Pool

type Item struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

func main() {
	msg := os.Getenv("DEMO_BACKEND_MESSAGE")
	if msg == "" {
		msg = "Hello from demo-backend"
	}

	// Database connection (optional)
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL != "" {
		log.Println("DATABASE_URL is set, connecting to database...")
		var err error
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		db, err = pgxpool.New(ctx, dbURL)
		if err != nil {
			log.Printf("WARNING: Failed to connect to database: %v", err)
			log.Println("Continuing without database support")
			db = nil
		} else {
			if err := db.Ping(ctx); err != nil {
				log.Printf("WARNING: Failed to ping database: %v", err)
				db.Close()
				db = nil
			} else {
				log.Println("Connected to database successfully")
			}
		}
	} else {
		log.Println("DATABASE_URL not set, running without database support")
	}

	http.HandleFunc("/healthz", handleHealthz)
	http.HandleFunc("/api/hello", handleHello(msg))
	http.HandleFunc("/api/items", handleItems)

	log.Println("demo-backend listening on :8000")
	log.Fatal(http.ListenAndServe(":8000", nil))
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func handleHello(msg string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"message": msg})
	}
}

func handleItems(w http.ResponseWriter, r *http.Request) {
	if db == nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"error": "database not configured",
		})
		return
	}

	switch r.Method {
	case http.MethodGet:
		listItems(w, r)
	case http.MethodPost:
		createItem(w, r)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func listItems(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := db.Query(ctx, "SELECT id, name, created_at FROM items ORDER BY created_at DESC")
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var item Item
		if err := rows.Scan(&item.ID, &item.Name, &item.CreatedAt); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		items = append(items, item)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(items)
}

func createItem(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Name string `json:"name"`
	}

	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid JSON"})
		return
	}

	if input.Name == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "name is required"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var item Item
	err := db.QueryRow(ctx,
		"INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at",
		input.Name,
	).Scan(&item.ID, &item.Name, &item.CreatedAt)

	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(item)
}
