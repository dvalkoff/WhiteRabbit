package config

import (
	"fmt"
	"os"
)

// Config is the full server configuration, loaded from environment variables.
type Config struct {
	HTTPAddr    string
	DatabaseURL string
	RedisAddr   string
	JWTSecret   string

	MinioEndpoint  string
	MinioAccessKey string
	MinioSecretKey string
	MinioBucket    string

	// InstanceID identifies this server process in logs/metrics. Auto-derived
	// from hostname+pid when empty. Not required for correctness of routing.
	InstanceID string
}

// Load reads configuration from the environment, applying dev-friendly
// defaults. It returns an error only when a required secret is missing.
func Load() (Config, error) {
	c := Config{
		HTTPAddr:       env("WR_HTTP_ADDR", ":8080"),
		DatabaseURL:    env("WR_DATABASE_URL", "postgres://whiterabbit:whiterabbit@localhost:5432/whiterabbit?sslmode=disable"),
		RedisAddr:      env("WR_REDIS_ADDR", "localhost:6379"),
		JWTSecret:      env("WR_JWT_SECRET", ""),
		MinioEndpoint:  env("WR_MINIO_ENDPOINT", "localhost:9000"),
		MinioAccessKey: env("WR_MINIO_ACCESS_KEY", "minioadmin"),
		MinioSecretKey: env("WR_MINIO_SECRET_KEY", "minioadmin"),
		MinioBucket:    env("WR_MINIO_BUCKET", "wr-blobs"),
		InstanceID:     env("WR_INSTANCE_ID", ""),
	}
	if c.JWTSecret == "" {
		return Config{}, fmt.Errorf("WR_JWT_SECRET is required")
	}
	if c.InstanceID == "" {
		host, _ := os.Hostname()
		c.InstanceID = fmt.Sprintf("%s-%d", host, os.Getpid())
	}
	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
