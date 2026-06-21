// Command server is the WhiteRabbit realtime messenger backend: an E2E-blind
// relay. It serves the HTTP API (auth, prekeys, search) and the websocket
// realtime layer, scaling horizontally via Redis Pub/Sub.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/whiterabbit/server/internal/api"
	"github.com/whiterabbit/server/internal/auth"
	"github.com/whiterabbit/server/internal/config"
	"github.com/whiterabbit/server/internal/files"
	"github.com/whiterabbit/server/internal/store"
	"github.com/whiterabbit/server/internal/ws"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg, err := config.Load()
	if err != nil {
		log.Error("load config", "err", err)
		os.Exit(1)
	}
	log = log.With("instance", cfg.InstanceID)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Apply migrations before serving.
	if err := store.Migrate(cfg.DatabaseURL); err != nil {
		log.Error("migrate", "err", err)
		os.Exit(1)
	}

	st, err := store.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("connect store", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Error("connect redis", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	hub := ws.NewHub(ctx, rdb, st, log, cfg.InstanceID)
	defer hub.Close()

	fileSvc, err := files.New(ctx, files.Config{
		Endpoint:       cfg.MinioEndpoint,
		PublicEndpoint: cfg.MinioPublicEndpoint,
		AccessKey:      cfg.MinioAccessKey,
		SecretKey:      cfg.MinioSecretKey,
		Bucket:         cfg.MinioBucket,
	})
	if err != nil {
		log.Error("init files", "err", err)
		os.Exit(1)
	}

	tokens := auth.NewTokenManager(cfg.JWTSecret)
	a := api.New(st, tokens, hub, fileSvc, log)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           a.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Info("listening", "addr", cfg.HTTPAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http server", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}
