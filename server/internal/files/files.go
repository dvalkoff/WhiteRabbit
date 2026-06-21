// Package files issues presigned MinIO URLs so clients can upload and download
// encrypted blobs directly to object storage. The server never sees plaintext:
// clients encrypt blobs locally and only the ciphertext is stored. The server
// also never streams the bytes — it just hands out short-lived signed URLs.
package files

import (
	"context"
	"fmt"
	"net/url"
	"time"

	"github.com/google/uuid"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Service wraps two MinIO clients: one reachable from the server (for bucket
// management) and one configured with the client-facing endpoint (used purely to
// generate presigned URLs whose signature matches the host the app connects to).
type Service struct {
	internal *minio.Client
	public   *minio.Client
	bucket   string
	expiry   time.Duration
}

// Config for the file service.
type Config struct {
	Endpoint       string // server-reachable, e.g. minio:9000
	PublicEndpoint string // client-reachable, e.g. localhost:9000
	AccessKey      string
	SecretKey      string
	Bucket         string
}

// New creates the service and ensures the bucket exists.
func New(ctx context.Context, cfg Config) (*Service, error) {
	creds := credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, "")
	internal, err := minio.New(cfg.Endpoint, &minio.Options{Creds: creds, Secure: false, Region: "us-east-1"})
	if err != nil {
		return nil, fmt.Errorf("minio internal client: %w", err)
	}
	// Region is set explicitly so presigning never makes a GetBucketLocation
	// call — that would try to reach the public endpoint from inside the server.
	public, err := minio.New(cfg.PublicEndpoint, &minio.Options{Creds: creds, Secure: false, Region: "us-east-1"})
	if err != nil {
		return nil, fmt.Errorf("minio public client: %w", err)
	}

	exists, err := internal.BucketExists(ctx, cfg.Bucket)
	if err != nil {
		return nil, fmt.Errorf("check bucket: %w", err)
	}
	if !exists {
		if err := internal.MakeBucket(ctx, cfg.Bucket, minio.MakeBucketOptions{}); err != nil {
			return nil, fmt.Errorf("make bucket: %w", err)
		}
	}

	return &Service{internal: internal, public: public, bucket: cfg.Bucket, expiry: 15 * time.Minute}, nil
}

// NewUploadURL mints a fresh object key and a presigned PUT URL for it.
func (s *Service) NewUploadURL(ctx context.Context) (key string, putURL string, err error) {
	key = "blobs/" + uuid.NewString()
	u, err := s.public.PresignedPutObject(ctx, s.bucket, key, s.expiry)
	if err != nil {
		return "", "", err
	}
	return key, u.String(), nil
}

// DownloadURL returns a presigned GET URL for an existing object key.
func (s *Service) DownloadURL(ctx context.Context, key string) (string, error) {
	u, err := s.public.PresignedGetObject(ctx, s.bucket, key, s.expiry, url.Values{})
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

// ExpirySeconds is the lifetime of issued URLs, for the client to know.
func (s *Service) ExpirySeconds() int { return int(s.expiry.Seconds()) }
