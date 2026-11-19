package spool

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// S3Config points at the same Garage/S3 store Rails uses (config/storage.yml):
// path-style addressing, static credentials.
type S3Config struct {
	Endpoint  string // e.g. http://localhost:4900
	Bucket    string // e.g. inbox2-attachments
	AccessKey string
	SecretKey string
	Region    string // e.g. garage
}

func (c S3Config) Configured() bool {
	return c.Endpoint != "" && c.Bucket != "" && c.AccessKey != "" && c.SecretKey != ""
}

// S3Client is a thin ObjectPutter over minio-go.
type S3Client struct {
	client *minio.Client
	bucket string
}

func NewS3Client(cfg S3Config) (*S3Client, error) {
	u, err := url.Parse(cfg.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse s3 endpoint: %w", err)
	}
	client, err := minio.New(u.Host, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.AccessKey, cfg.SecretKey, ""),
		Secure: strings.EqualFold(u.Scheme, "https"),
		Region: cfg.Region,
	})
	if err != nil {
		return nil, fmt.Errorf("s3 client: %w", err)
	}
	return &S3Client{client: client, bucket: cfg.Bucket}, nil
}

func (c *S3Client) PutObject(ctx context.Context, objectKey string, data []byte, contentType string) error {
	_, err := c.client.PutObject(ctx, c.bucket, objectKey, bytes.NewReader(data), int64(len(data)),
		minio.PutObjectOptions{ContentType: contentType})
	return err
}
